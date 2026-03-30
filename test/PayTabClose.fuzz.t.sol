// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCCloseFuzz
/// @notice Minimal ERC-20 mock for closeTab fuzz testing.
contract MockUSDCCloseFuzz {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) return false;
        if (allowance[from][msg.sender] < amount) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external pure {}
}

/// @title PayTabCloseFuzzTest
/// @notice Property-based fuzz tests for PayTab.closeTab
contract PayTabCloseFuzzTest is Test {
    PayTab internal payTab;
    PayFee internal fee;
    MockUSDCCloseFuzz internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    uint96 constant MIN_TAB = PayTypes.MIN_TAB_AMOUNT;
    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS;

    function setUp() public {
        usdc = new MockUSDCCloseFuzz();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        payTab = new PayTab(address(usdc), address(fee), feeWallet, relayer);

        vm.prank(owner);
        fee.authorizeCaller(address(payTab));

        vm.warp(1773532800);
    }

    /// @dev Helper: open tab, charge, close, return distribution.
    function _openChargeClose(uint96 tabAmount, uint96 chargeAmount)
        internal
        returns (uint96 balance, uint96 providerGot, uint96 feeGot, uint96 agentGot)
    {
        bytes32 tabId = bytes32(uint256(tabAmount) ^ uint256(chargeAmount));

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), tabAmount);
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount); // maxCharge = tabAmount

        balance = payTab.getTab(tabId).amount;

        if (chargeAmount > 0 && chargeAmount <= balance) {
            vm.prank(relayer);
            payTab.chargeTab(tabId, chargeAmount);
        }

        uint256 pBefore = usdc.balanceOf(provider);
        uint256 fBefore = usdc.balanceOf(feeWallet);
        uint256 aBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        payTab.closeTab(tabId);

        providerGot = uint96(usdc.balanceOf(provider) - pBefore);
        feeGot = uint96(usdc.balanceOf(feeWallet) - fBefore);
        agentGot = uint96(usdc.balanceOf(agent) - aBefore);
    }

    // =========================================================================
    // Property: USDC conservation through full lifecycle
    // =========================================================================

    /// @dev provider + fee + agent refund == tab balance for any amount/charge combo.
    function testFuzz_closeConservesUsdc(uint96 tabAmount, uint96 chargeAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));
        chargeAmount = uint96(bound(chargeAmount, 0, tabAmount));

        (uint96 balance, uint96 providerGot, uint96 feeGot, uint96 agentGot) =
            _openChargeClose(tabAmount, chargeAmount);

        // Allow chargeAmount to be capped at actual balance
        uint96 effectiveCharge = chargeAmount <= balance ? chargeAmount : 0;

        if (effectiveCharge > 0) {
            assertEq(providerGot + feeGot + agentGot, balance, "distribution must sum to tab balance");
        } else {
            // No charge → full refund
            assertEq(agentGot, balance, "no charges → full refund");
            assertEq(providerGot, 0);
            assertEq(feeGot, 0);
        }
    }

    // =========================================================================
    // Property: provider always gets majority of totalCharged
    // =========================================================================

    /// @dev Provider receives >= 99% of totalCharged (at standard rate).
    function testFuzz_providerGetsMajority(uint96 tabAmount, uint96 chargeAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        bytes32 tabId = bytes32("majority");
        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), tabAmount);
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;
        chargeAmount = uint96(bound(chargeAmount, 1, balance));

        vm.prank(relayer);
        payTab.chargeTab(tabId, chargeAmount);

        vm.prank(agent);
        payTab.closeTab(tabId);

        assertGe(usdc.balanceOf(provider), uint256(chargeAmount) * 99 / 100, "provider must get >= 99% of charged");
    }

    // =========================================================================
    // Property: fee never exceeds totalCharged
    // =========================================================================

    /// @dev Processing fee is always < totalCharged.
    function testFuzz_feeLessThanCharged(uint96 tabAmount, uint96 chargeAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        bytes32 tabId = bytes32("feecap");
        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), tabAmount);
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;
        chargeAmount = uint96(bound(chargeAmount, 1, balance));

        vm.prank(relayer);
        payTab.chargeTab(tabId, chargeAmount);

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(agent);
        payTab.closeTab(tabId);

        uint256 feeGained = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertLt(feeGained, chargeAmount, "fee must be less than total charged");
    }

    // =========================================================================
    // Property: closed tab has zero contract balance for that tab
    // =========================================================================

    /// @dev After close, the tab's remaining amount is 0.
    function testFuzz_closedTabAmountZero(uint96 tabAmount, uint96 chargeAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        bytes32 tabId = bytes32("zero");
        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), tabAmount);
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;
        chargeAmount = uint96(bound(chargeAmount, 0, balance));

        if (chargeAmount > 0) {
            vm.prank(relayer);
            payTab.chargeTab(tabId, chargeAmount);
        }

        vm.prank(agent);
        payTab.closeTab(tabId);

        assertEq(payTab.getTab(tabId).amount, 0, "closed tab must have 0 amount");
        assertEq(uint8(payTab.getTab(tabId).status), uint8(PayTypes.TabStatus.Closed));
    }

    // =========================================================================
    // Property: any of 3 callers can close
    // =========================================================================

    /// @dev Agent, provider, and relayer can all close. Others cannot.
    function testFuzz_onlyAuthorizedCanClose(uint8 callerType) public {
        callerType = uint8(bound(callerType, 0, 3));

        bytes32 tabId = bytes32(uint256(callerType));
        usdc.mint(agent, 10e6);
        vm.prank(agent);
        usdc.approve(address(payTab), 10e6);
        vm.prank(agent);
        payTab.openTab(tabId, provider, 10e6, 10e6);

        address caller;
        if (callerType == 0) caller = agent;
        else if (callerType == 1) caller = provider;
        else if (callerType == 2) caller = relayer;
        else caller = makeAddr("unauthorized");

        if (callerType <= 2) {
            vm.prank(caller);
            payTab.closeTab(tabId);
            assertEq(uint8(payTab.getTab(tabId).status), uint8(PayTypes.TabStatus.Closed));
        } else {
            vm.expectRevert();
            vm.prank(caller);
            payTab.closeTab(tabId);
        }
    }

    // =========================================================================
    // Property: volume recorded on close matches totalCharged
    // =========================================================================

    /// @dev PayFee monthly volume == totalCharged after close.
    function testFuzz_volumeMatchesTotalCharged(uint96 tabAmount, uint96 chargeAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        bytes32 tabId = bytes32("vol");
        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), tabAmount);
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;
        chargeAmount = uint96(bound(chargeAmount, 0, balance));

        if (chargeAmount > 0) {
            vm.prank(relayer);
            payTab.chargeTab(tabId, chargeAmount);
        }

        vm.prank(agent);
        payTab.closeTab(tabId);

        assertEq(fee.getMonthlyVolume(provider), chargeAmount, "volume must equal totalCharged");
    }
}

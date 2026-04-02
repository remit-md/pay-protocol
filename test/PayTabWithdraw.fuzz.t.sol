// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCWithdrawFuzz
contract MockUSDCWithdrawFuzz {
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

/// @title PayTabWithdrawFuzzTest
/// @notice Fuzz tests for withdrawCharged + closeTab distribution
contract PayTabWithdrawFuzzTest is Test {
    PayTab internal tab;
    PayFee internal fee;
    MockUSDCWithdrawFuzz internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayerAddr = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS;

    function setUp() public {
        usdc = new MockUSDCWithdrawFuzz();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTab(address(usdc), address(fee), feeWallet, relayerAddr);

        vm.prank(owner);
        fee.authorizeCaller(address(tab));

        usdc.mint(agent, type(uint96).max);
        vm.prank(agent);
        usdc.approve(address(tab), type(uint256).max);

        vm.warp(1773532800);
    }

    /// @notice Fuzz: charge random amount, withdraw, close — USDC conserved
    function testFuzz_withdrawThenClose_usdcConserved(uint96 tabAmount, uint96 chargeAmount) public {
        // Bound tab amount to valid range
        tabAmount = uint96(bound(tabAmount, PayTypes.MIN_TAB_AMOUNT, 1_000_000e6));
        uint96 maxCharge = tabAmount; // allow full-tab charges

        bytes32 tabId = bytes32("fuzz-conserve");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, maxCharge);

        uint96 tabBalance = tab.getTab(tabId).amount;
        chargeAmount = uint96(bound(chargeAmount, 1, tabBalance));

        // Charge
        vm.prank(relayerAddr);
        tab.chargeTab(tabId, chargeAmount);

        uint256 totalBefore =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        // Withdraw
        vm.prank(provider);
        tab.withdrawCharged(tabId);

        // Close
        vm.prank(agent);
        tab.closeTab(tabId);

        uint256 totalAfter =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        assertEq(totalAfter, totalBefore, "USDC must be conserved through withdraw + close");
        assertEq(usdc.balanceOf(address(tab)), 0, "contract must be empty after close");
    }

    /// @notice Fuzz: withdraw + close distribution sums to tab balance
    function testFuzz_withdrawThenClose_distributionSums(uint96 tabAmount, uint96 chargeAmount) public {
        tabAmount = uint96(bound(tabAmount, PayTypes.MIN_TAB_AMOUNT, 1_000_000e6));

        bytes32 tabId = bytes32("fuzz-dist");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 tabBalance = tab.getTab(tabId).amount;
        chargeAmount = uint96(bound(chargeAmount, 1, tabBalance));

        vm.prank(relayerAddr);
        tab.chargeTab(tabId, chargeAmount);

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(provider);
        tab.withdrawCharged(tabId);

        vm.prank(agent);
        tab.closeTab(tabId);

        uint256 providerGain = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGain = usdc.balanceOf(feeWallet) - feeWalletBefore;
        uint256 agentGain = usdc.balanceOf(agent) - agentBefore;

        assertEq(providerGain + feeGain + agentGain, tabBalance, "distribution must sum to tab balance");
    }
}

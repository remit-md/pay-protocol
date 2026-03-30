// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDCCharge
/// @notice Minimal ERC-20 mock for chargeTab testing.
contract MockUSDCCharge {
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

/// @title PayTabChargeTest
/// @notice Unit tests for PayTab.chargeTab
contract PayTabChargeTest is Test {
    PayTab internal tab;
    PayFee internal fee;
    MockUSDCCharge internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    bytes32 constant TAB_ID = bytes32("tab-001");
    uint96 constant TAB_AMOUNT = 100e6; // $100
    uint96 constant MAX_CHARGE = 5e6; // $5 per call

    /// @dev Tab balance after activation fee: $100 - $1 = $99
    uint96 internal tabBalance;

    function setUp() public {
        usdc = new MockUSDCCharge();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTab(address(usdc), address(fee), feeWallet, relayer);

        vm.prank(owner);
        fee.authorizeCaller(address(tab));

        usdc.mint(agent, 1_000_000e6);
        vm.prank(agent);
        usdc.approve(address(tab), type(uint256).max);

        // Open a standard tab for testing charges
        vm.prank(agent);
        tab.openTab(TAB_ID, provider, TAB_AMOUNT, MAX_CHARGE);

        tabBalance = tab.getTab(TAB_ID).amount; // $99 after 1% activation fee
    }

    // =========================================================================
    // chargeTab — happy path
    // =========================================================================

    function test_chargeTab_decrementsBalance() public {
        uint96 charge = 1e6; // $1

        vm.prank(relayer);
        tab.chargeTab(TAB_ID, charge);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.amount, tabBalance - charge);
        assertEq(t.totalCharged, charge);
        assertEq(t.chargeCount, 1);
    }

    function test_chargeTab_multipleCharges() public {
        vm.startPrank(relayer);
        tab.chargeTab(TAB_ID, 1e6);
        tab.chargeTab(TAB_ID, 2e6);
        tab.chargeTab(TAB_ID, 500_000);
        vm.stopPrank();

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.amount, tabBalance - 3_500_000);
        assertEq(t.totalCharged, 3_500_000);
        assertEq(t.chargeCount, 3);
    }

    function test_chargeTab_exactMaxCharge() public {
        // Charge exactly maxChargePerCall — should succeed
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, MAX_CHARGE);

        assertEq(tab.getTab(TAB_ID).totalCharged, MAX_CHARGE);
    }

    function test_chargeTab_smallCharge() public {
        // Charge 1 unit (smallest non-zero amount)
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 1);

        assertEq(tab.getTab(TAB_ID).totalCharged, 1);
        assertEq(tab.getTab(TAB_ID).chargeCount, 1);
    }

    function test_chargeTab_noUsdcTransfer() public {
        // chargeTab only updates storage — no USDC moves
        uint256 contractBefore = usdc.balanceOf(address(tab));
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 2e6);

        assertEq(usdc.balanceOf(address(tab)), contractBefore, "contract balance must not change");
        assertEq(usdc.balanceOf(provider), providerBefore, "provider balance must not change");
        assertEq(usdc.balanceOf(feeWallet), feeWalletBefore, "feeWallet balance must not change");
    }

    function test_chargeTab_emitsEvent() public {
        uint96 charge = 3e6;

        vm.expectEmit(true, false, false, true);
        emit PayEvents.TabCharged(TAB_ID, charge, tabBalance - charge, 1);

        vm.prank(relayer);
        tab.chargeTab(TAB_ID, charge);
    }

    function test_chargeTab_emitsCorrectCountOnSecondCharge() public {
        vm.startPrank(relayer);
        tab.chargeTab(TAB_ID, 1e6);

        vm.expectEmit(true, false, false, true);
        emit PayEvents.TabCharged(TAB_ID, 2e6, tabBalance - 3e6, 2);

        tab.chargeTab(TAB_ID, 2e6);
        vm.stopPrank();
    }

    function test_chargeTab_drainToZero() public {
        // Charge the entire balance in MAX_CHARGE increments
        uint96 remaining = tabBalance;
        uint256 count = 0;

        vm.startPrank(relayer);
        while (remaining >= MAX_CHARGE) {
            tab.chargeTab(TAB_ID, MAX_CHARGE);
            remaining -= MAX_CHARGE;
            count++;
        }
        if (remaining > 0) {
            tab.chargeTab(TAB_ID, remaining);
            count++;
        }
        vm.stopPrank();

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.amount, 0);
        assertEq(t.totalCharged, tabBalance);
        assertEq(t.chargeCount, count);
        // Tab is still Active even at zero balance (close is separate)
        assertEq(uint8(t.status), uint8(PayTypes.TabStatus.Active));
    }

    // =========================================================================
    // chargeTab — reverts
    // =========================================================================

    function test_chargeTab_revertsForNonRelayer() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tab.chargeTab(TAB_ID, 1e6);
    }

    function test_chargeTab_revertsForAgent() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, agent));
        vm.prank(agent);
        tab.chargeTab(TAB_ID, 1e6);
    }

    function test_chargeTab_revertsForProvider() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, provider));
        vm.prank(provider);
        tab.chargeTab(TAB_ID, 1e6);
    }

    function test_chargeTab_revertsOnNonexistentTab() public {
        bytes32 fakeId = bytes32("nonexistent");
        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabNotFound.selector, fakeId));
        vm.prank(relayer);
        tab.chargeTab(fakeId, 1e6);
    }

    function test_chargeTab_revertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAmount.selector));
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 0);
    }

    function test_chargeTab_revertsOnExceedMaxCharge() public {
        uint96 tooMuch = MAX_CHARGE + 1;
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ChargeLimitExceeded.selector, TAB_ID, tooMuch, MAX_CHARGE));
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, tooMuch);
    }

    function test_chargeTab_revertsOnExceedBalance() public {
        // Drain most of the balance first
        uint96 remaining = tabBalance;
        vm.startPrank(relayer);
        while (remaining > MAX_CHARGE) {
            tab.chargeTab(TAB_ID, MAX_CHARGE);
            remaining -= MAX_CHARGE;
        }
        vm.stopPrank();

        // Now try to charge more than remaining
        if (remaining < MAX_CHARGE) {
            uint96 overcharge = remaining + 1;
            // Only revert if overcharge <= maxCharge (otherwise ChargeLimitExceeded fires first)
            if (overcharge <= MAX_CHARGE) {
                vm.expectRevert(
                    abi.encodeWithSelector(PayErrors.InsufficientBalance.selector, TAB_ID, overcharge, remaining)
                );
                vm.prank(relayer);
                tab.chargeTab(TAB_ID, overcharge);
            }
        }
    }

    function test_chargeTab_revertsOnExceedBalance_afterDrain() public {
        // Drain to zero
        uint96 remaining = tabBalance;
        vm.startPrank(relayer);
        while (remaining >= MAX_CHARGE) {
            tab.chargeTab(TAB_ID, MAX_CHARGE);
            remaining -= MAX_CHARGE;
        }
        if (remaining > 0) {
            tab.chargeTab(TAB_ID, remaining);
        }
        vm.stopPrank();

        // Any charge on zero balance should revert
        vm.expectRevert(abi.encodeWithSelector(PayErrors.InsufficientBalance.selector, TAB_ID, uint96(1), uint96(0)));
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 1);
    }

    // =========================================================================
    // chargeTab — maxChargePerCall enforcement
    // =========================================================================

    function test_maxCharge_enforcedPerCall() public {
        // Each call must be <= MAX_CHARGE, regardless of remaining balance
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, MAX_CHARGE); // ok

        vm.expectRevert(
            abi.encodeWithSelector(PayErrors.ChargeLimitExceeded.selector, TAB_ID, MAX_CHARGE + 1, MAX_CHARGE)
        );
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, MAX_CHARGE + 1); // reverts
    }

    function test_maxCharge_doesNotAccumulate() public {
        // Making small charges doesn't "save up" capacity for a bigger one
        vm.startPrank(relayer);
        tab.chargeTab(TAB_ID, 1e6); // $1 (under $5 max)
        tab.chargeTab(TAB_ID, 1e6); // $1

        // Still can't charge more than $5 in a single call
        vm.expectRevert(
            abi.encodeWithSelector(PayErrors.ChargeLimitExceeded.selector, TAB_ID, MAX_CHARGE + 1, MAX_CHARGE)
        );
        tab.chargeTab(TAB_ID, MAX_CHARGE + 1);
        vm.stopPrank();
    }

    // =========================================================================
    // chargeTab — different tabs are independent
    // =========================================================================

    function test_chargeTab_independentTabs() public {
        bytes32 tab2Id = bytes32("tab-002");
        vm.prank(agent);
        tab.openTab(tab2Id, provider, 50e6, 10e6);

        vm.startPrank(relayer);
        tab.chargeTab(TAB_ID, 3e6);
        tab.chargeTab(tab2Id, 7e6);
        vm.stopPrank();

        assertEq(tab.getTab(TAB_ID).totalCharged, 3e6);
        assertEq(tab.getTab(tab2Id).totalCharged, 7e6);
        assertEq(tab.getTab(TAB_ID).chargeCount, 1);
        assertEq(tab.getTab(tab2Id).chargeCount, 1);
    }

    // =========================================================================
    // chargeTab — tab balance invariant
    // =========================================================================

    function test_chargeTab_balanceInvariant() public {
        // After any number of charges: amount + totalCharged == original tabBalance
        vm.startPrank(relayer);
        tab.chargeTab(TAB_ID, 2e6);
        tab.chargeTab(TAB_ID, 3e6);
        tab.chargeTab(TAB_ID, 1e6);
        vm.stopPrank();

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.amount + t.totalCharged, tabBalance, "amount + totalCharged must equal original balance");
    }
}

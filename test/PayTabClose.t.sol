// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDCClose
/// @notice Minimal ERC-20 mock for closeTab testing.
contract MockUSDCClose {
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

/// @title PayTabCloseTest
/// @notice Unit tests for PayTab.closeTab
contract PayTabCloseTest is Test {
    PayTab internal tab;
    PayFee internal fee;
    MockUSDCClose internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    bytes32 constant TAB_ID = bytes32("tab-001");
    uint96 constant TAB_AMOUNT = 100e6; // $100
    uint96 constant MAX_CHARGE = 10e6; // $10 per call

    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS;

    uint96 internal tabBalance;

    function setUp() public {
        usdc = new MockUSDCClose();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTab(address(usdc), address(fee), feeWallet, relayer);

        vm.prank(owner);
        fee.authorizeCaller(address(tab));

        usdc.mint(agent, 1_000_000e6);
        vm.prank(agent);
        usdc.approve(address(tab), type(uint256).max);

        // Open a standard tab
        vm.prank(agent);
        tab.openTab(TAB_ID, provider, TAB_AMOUNT, MAX_CHARGE);
        tabBalance = tab.getTab(TAB_ID).amount; // $99 after 1% activation fee

        // Warp to known date
        vm.warp(1773532800);
    }

    // =========================================================================
    // closeTab — agent closes after charges
    // =========================================================================

    function test_closeTab_agentCloses_withCharges() public {
        // Charge $30 total
        vm.startPrank(relayer);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();

        uint96 totalCharged = 30e6;
        uint96 expectedFee = uint96((uint256(totalCharged) * STANDARD_BPS) / 10_000);
        uint96 expectedPayout = totalCharged - expectedFee;
        uint96 expectedRefund = tabBalance - totalCharged;

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(uint8(t.status), uint8(PayTypes.TabStatus.Closed));
        assertEq(t.amount, 0);

        assertEq(usdc.balanceOf(provider), expectedPayout);
        // feeWallet has activation fee from open + processing fee from close
        uint96 activationFee = tab.getTab(TAB_ID).activationFee;
        assertEq(usdc.balanceOf(feeWallet), activationFee + expectedFee);
        assertEq(usdc.balanceOf(address(tab)), 0); // all funds distributed
    }

    function test_closeTab_providerCloses() public {
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 5e6);

        vm.prank(provider);
        tab.closeTab(TAB_ID);

        assertEq(uint8(tab.getTab(TAB_ID).status), uint8(PayTypes.TabStatus.Closed));
        assertGt(usdc.balanceOf(provider), 0);
    }

    function test_closeTab_relayerCloses() public {
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 5e6);

        vm.prank(relayer);
        tab.closeTab(TAB_ID);

        assertEq(uint8(tab.getTab(TAB_ID).status), uint8(PayTypes.TabStatus.Closed));
    }

    // =========================================================================
    // closeTab — no charges (full refund)
    // =========================================================================

    function test_closeTab_noCharges_fullRefund() public {
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        // Agent gets full tab balance back (not activation fee — that was already sent)
        assertEq(usdc.balanceOf(agent), agentBefore + tabBalance);
        // Provider gets nothing
        assertEq(usdc.balanceOf(provider), 0);
        // Contract holds nothing
        assertEq(usdc.balanceOf(address(tab)), 0);
    }

    function test_closeTab_noCharges_noFee() public {
        uint96 activationFee = tab.getTab(TAB_ID).activationFee;
        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);
        assertEq(feeWalletBefore, activationFee); // only activation fee from open

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        // feeWallet should not receive any additional fee
        assertEq(usdc.balanceOf(feeWallet), feeWalletBefore);
    }

    // =========================================================================
    // closeTab — fully drained tab
    // =========================================================================

    function test_closeTab_fullyDrained() public {
        // Drain entire balance
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

        uint96 totalCharged = tabBalance;
        uint96 expectedFee = uint96((uint256(totalCharged) * STANDARD_BPS) / 10_000);
        uint96 expectedPayout = totalCharged - expectedFee;

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        assertEq(usdc.balanceOf(provider), expectedPayout);
        // Agent gets 0 refund (fully drained)
        // feeWallet gets activation fee + processing fee
    }

    // =========================================================================
    // closeTab — emits event
    // =========================================================================

    function test_closeTab_emitsEvent() public {
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 20e6);

        uint96 totalCharged = 20e6;
        uint96 expectedFee = uint96((uint256(totalCharged) * STANDARD_BPS) / 10_000);
        uint96 expectedPayout = totalCharged - expectedFee;
        uint96 expectedRefund = tabBalance - totalCharged;

        vm.expectEmit(true, false, false, true);
        emit PayEvents.TabClosed(TAB_ID, totalCharged, expectedPayout, expectedFee, expectedRefund);

        vm.prank(agent);
        tab.closeTab(TAB_ID);
    }

    // =========================================================================
    // closeTab — records volume on PayFee
    // =========================================================================

    function test_closeTab_recordsVolume() public {
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 15e6);

        assertEq(fee.getMonthlyVolume(provider), 0); // not recorded yet

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        assertEq(fee.getMonthlyVolume(provider), 15e6);
    }

    // =========================================================================
    // closeTab — USDC conservation
    // =========================================================================

    function test_closeTab_usdcConserved() public {
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 25e6);

        uint256 totalBefore =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint256 totalAfter =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        assertEq(totalAfter, totalBefore, "USDC must be conserved through close");
    }

    // =========================================================================
    // closeTab — reverts
    // =========================================================================

    function test_closeTab_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tab.closeTab(TAB_ID);
    }

    function test_closeTab_revertsOnNonexistentTab() public {
        bytes32 fakeId = bytes32("nonexistent");
        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabNotFound.selector, fakeId));
        vm.prank(agent);
        tab.closeTab(fakeId);
    }

    function test_closeTab_revertsOnAlreadyClosed() public {
        vm.prank(agent);
        tab.closeTab(TAB_ID);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabClosed.selector, TAB_ID));
        vm.prank(agent);
        tab.closeTab(TAB_ID);
    }

    function test_closeTab_cannotChargeAfterClose() public {
        vm.prank(agent);
        tab.closeTab(TAB_ID);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabClosed.selector, TAB_ID));
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 1e6);
    }

    // =========================================================================
    // closeTab — provider + fee + refund sum to tabBalance
    // =========================================================================

    function test_closeTab_distributionSumsToTabBalance() public {
        vm.prank(relayer);
        tab.chargeTab(TAB_ID, 42e6); // non-round number

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint256 providerGain = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGain = usdc.balanceOf(feeWallet) - feeWalletBefore;
        uint256 agentGain = usdc.balanceOf(agent) - agentBefore;

        assertEq(providerGain + feeGain + agentGain, tabBalance, "distribution must sum to original tab balance");
    }

    // =========================================================================
    // closeTab — multiple tabs independent
    // =========================================================================

    function test_closeTab_independentTabs() public {
        // Open second tab
        bytes32 tab2Id = bytes32("tab-002");
        vm.prank(agent);
        tab.openTab(tab2Id, provider, 50e6, 10e6);

        // Charge both
        vm.startPrank(relayer);
        tab.chargeTab(TAB_ID, 5e6);
        tab.chargeTab(tab2Id, 3e6);
        vm.stopPrank();

        // Close first only
        vm.prank(agent);
        tab.closeTab(TAB_ID);

        // Second tab still active
        assertEq(uint8(tab.getTab(tab2Id).status), uint8(PayTypes.TabStatus.Active));

        // Can still charge second tab
        vm.prank(relayer);
        tab.chargeTab(tab2Id, 2e6);
        assertEq(tab.getTab(tab2Id).totalCharged, 5e6);
    }
}

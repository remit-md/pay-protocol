// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDCWithdraw
/// @notice Minimal ERC-20 mock for withdrawCharged testing.
contract MockUSDCWithdraw {
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

/// @title PayTabWithdrawTest
/// @notice Unit tests for PayTab.withdrawCharged
contract PayTabWithdrawTest is Test {
    PayTab internal tab;
    PayFee internal fee;
    MockUSDCWithdraw internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayerAddr = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    bytes32 constant TAB_ID = bytes32("tab-001");
    uint96 constant TAB_AMOUNT = 100e6; // $100
    uint96 constant MAX_CHARGE = 50e6; // $50 per call

    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS;

    uint96 internal tabBalance;

    function setUp() public {
        usdc = new MockUSDCWithdraw();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTab(address(usdc), address(fee), feeWallet, relayerAddr);

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
    // withdrawCharged — basic withdrawal
    // =========================================================================

    function test_withdrawCharged_basicWithdrawal() public {
        // Charge $30
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();

        uint96 charged = 30e6;
        uint96 expectedFee = uint96((uint256(charged) * STANDARD_BPS) / 10_000);
        uint96 expectedPayout = charged - expectedFee;

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        // Provider gets payout
        assertEq(usdc.balanceOf(provider), expectedPayout);
        // Fee wallet gets activation fee + processing fee
        uint96 activationFee = tab.getTab(TAB_ID).activationFee;
        assertEq(usdc.balanceOf(feeWallet), activationFee + expectedFee);

        // Tab is still active
        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(uint8(t.status), uint8(PayTypes.TabStatus.Active));
        assertEq(t.totalWithdrawn, charged);
        // Remaining balance unchanged by withdrawal
        assertEq(t.amount, tabBalance - charged);
    }

    // =========================================================================
    // withdrawCharged — multiple withdrawals
    // =========================================================================

    function test_withdrawCharged_multipleWithdrawals() public {
        // First round: charge $10, withdraw
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        uint96 fee1 = uint96((uint256(10e6) * STANDARD_BPS) / 10_000);
        uint96 payout1 = 10e6 - fee1;
        assertEq(usdc.balanceOf(provider), payout1);

        // Second round: charge $20 more, withdraw
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        uint96 fee2 = uint96((uint256(20e6) * STANDARD_BPS) / 10_000);
        uint96 payout2 = 20e6 - fee2;
        assertEq(usdc.balanceOf(provider), payout1 + payout2);

        // Tab state
        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.totalWithdrawn, 30e6);
        assertEq(t.totalCharged, 30e6);
    }

    // =========================================================================
    // withdrawCharged — then close
    // =========================================================================

    function test_withdrawCharged_thenClose() public {
        // Charge $50, withdraw $30 worth, charge $20 more
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 30e6);
        vm.stopPrank();

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        uint96 withdrawFee = uint96((uint256(30e6) * STANDARD_BPS) / 10_000);
        uint96 withdrawPayout = 30e6 - withdrawFee;

        // Charge $20 more
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 20e6);

        // Close — should only distribute unwithdrawn $20
        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint96 closeFee = uint96((uint256(20e6) * STANDARD_BPS) / 10_000);
        uint96 closePayout = 20e6 - closeFee;

        // Provider total = withdraw payout + close payout
        assertEq(usdc.balanceOf(provider), withdrawPayout + closePayout);

        // Total fee = withdraw fee + close fee = fee on $50 total
        uint96 totalFee = withdrawFee + closeFee;
        uint96 expectedTotalFee = uint96((uint256(50e6) * STANDARD_BPS) / 10_000);
        assertEq(totalFee, expectedTotalFee, "total fee must equal fee on totalCharged");

        // Contract empty
        assertEq(usdc.balanceOf(address(tab)), 0);
    }

    // =========================================================================
    // withdrawCharged — nothing to withdraw
    // =========================================================================

    function test_withdrawCharged_nothingToWithdraw() public {
        // No charges — nothing to withdraw
        vm.expectRevert(abi.encodeWithSelector(PayErrors.NothingToWithdraw.selector, TAB_ID));
        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);
    }

    function test_withdrawCharged_nothingAfterFullWithdraw() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        // Second withdraw with no new charges
        vm.expectRevert(abi.encodeWithSelector(PayErrors.NothingToWithdraw.selector, TAB_ID));
        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);
    }

    // =========================================================================
    // withdrawCharged — minimum withdrawal ($1.00)
    // =========================================================================

    function test_withdrawCharged_belowMinimum() public {
        // Charge $0.50 — below $1.00 minimum
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 500_000);

        vm.expectRevert(
            abi.encodeWithSelector(PayErrors.BelowMinimum.selector, 500_000, PayTypes.MIN_DIRECT_AMOUNT)
        );
        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);
    }

    function test_withdrawCharged_exactMinimum() public {
        // Charge exactly $1.00 — should succeed
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 1_000_000);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        assertGt(usdc.balanceOf(provider), 0);
    }

    // =========================================================================
    // withdrawCharged — access control
    // =========================================================================

    function test_withdrawCharged_providerCanCall() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 5e6);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        assertGt(usdc.balanceOf(provider), 0);
    }

    function test_withdrawCharged_relayerCanCall() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 5e6);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        assertGt(usdc.balanceOf(provider), 0);
    }

    function test_withdrawCharged_agentCannotCall() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 5e6);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, agent));
        vm.prank(agent);
        tab.withdrawCharged(TAB_ID);
    }

    function test_withdrawCharged_strangerCannotCall() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 5e6);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tab.withdrawCharged(TAB_ID);
    }

    // =========================================================================
    // withdrawCharged — reverts on closed/nonexistent tab
    // =========================================================================

    function test_withdrawCharged_revertsOnClosedTab() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 5e6);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabClosed.selector, TAB_ID));
        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);
    }

    function test_withdrawCharged_revertsOnNonexistentTab() public {
        bytes32 fakeId = bytes32("nonexistent");
        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabNotFound.selector, fakeId));
        vm.prank(provider);
        tab.withdrawCharged(fakeId);
    }

    // =========================================================================
    // withdrawCharged — event emission
    // =========================================================================

    function test_withdrawCharged_emitsEvent() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 20e6);

        uint96 expectedFee = uint96((uint256(20e6) * STANDARD_BPS) / 10_000);
        uint96 expectedPayout = 20e6 - expectedFee;

        vm.expectEmit(true, false, false, true);
        emit PayEvents.TabWithdrawn(TAB_ID, expectedPayout, expectedFee, 20e6);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);
    }

    // =========================================================================
    // withdrawCharged — records volume
    // =========================================================================

    function test_withdrawCharged_recordsVolume() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 15e6);

        assertEq(fee.getMonthlyVolume(provider), 0);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        assertEq(fee.getMonthlyVolume(provider), 15e6);
    }

    // =========================================================================
    // withdrawCharged — USDC conservation
    // =========================================================================

    function test_withdrawCharged_usdcConserved() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 25e6);

        uint256 totalBefore =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        uint256 totalAfter =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        assertEq(totalAfter, totalBefore, "USDC must be conserved through withdrawal");
    }

    // =========================================================================
    // withdrawCharged — close after full withdrawal
    // =========================================================================

    function test_withdrawCharged_closeAfterFullWithdraw() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 40e6);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        uint256 providerBalAfterWithdraw = usdc.balanceOf(provider);

        // Close — no new charges since withdrawal
        vm.prank(agent);
        tab.closeTab(TAB_ID);

        // Provider gets nothing more at close (everything already withdrawn)
        assertEq(usdc.balanceOf(provider), providerBalAfterWithdraw);
        // Agent gets remaining balance
        uint96 remaining = tabBalance - 40e6;
        // Contract empty
        assertEq(usdc.balanceOf(address(tab)), 0);
    }

    // =========================================================================
    // withdrawCharged — does not affect agent's remaining balance
    // =========================================================================

    function test_withdrawCharged_doesNotAffectAgentBalance() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 20e6);

        uint96 remainingBefore = tab.getTab(TAB_ID).amount;

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        uint96 remainingAfter = tab.getTab(TAB_ID).amount;
        assertEq(remainingAfter, remainingBefore, "withdrawal must not touch remaining balance");
    }

    // =========================================================================
    // withdrawCharged + closeTab — distribution sums to tabBalance
    // =========================================================================

    function test_withdrawThenClose_distributionSumsToTabBalance() public {
        // Charge $42, withdraw, charge $17 more, close
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 42e6);

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);

        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 17e6);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint256 providerGain = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGain = usdc.balanceOf(feeWallet) - feeWalletBefore;
        uint256 agentGain = usdc.balanceOf(agent) - agentBefore;

        assertEq(providerGain + feeGain + agentGain, tabBalance, "distribution must sum to original tab balance");
    }

    // =========================================================================
    // closeTab — existing tests still work with totalWithdrawn == 0
    // =========================================================================

    function test_closeTab_noWithdrawals_worksAsBeforeID2() public {
        // Close without any withdrawals — same as original behavior
        bytes32 tab2 = bytes32("tab-nw-002");
        vm.prank(agent);
        tab.openTab(tab2, provider, 50e6, 25e6);
        uint96 tab2Balance = tab.getTab(tab2).amount;

        vm.prank(relayerAddr);
        tab.chargeTab(tab2, 20e6);

        uint256 contractBefore = usdc.balanceOf(address(tab));

        vm.prank(agent);
        tab.closeTab(tab2);

        // Tab2 funds fully distributed — contract balance dropped by tab2Balance
        assertEq(usdc.balanceOf(address(tab)), contractBefore - tab2Balance);
        assertGt(usdc.balanceOf(provider), 0);
        assertEq(uint8(tab.getTab(tab2).status), uint8(PayTypes.TabStatus.Closed));
    }
}

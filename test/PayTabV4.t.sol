// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTabV4} from "../src/PayTabV4.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDCV4
contract MockUSDCV4 {
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

/// @title PayTabV4Test
/// @notice Unit tests for PayTabV4 fee floor enforcement.
contract PayTabV4Test is Test {
    PayTabV4 internal tab;
    PayFee internal fee;
    MockUSDCV4 internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayerAddr = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    bytes32 constant TAB_ID = bytes32("tab-v4-001");
    uint96 constant TAB_AMOUNT = 100e6; // $100
    uint96 constant MAX_CHARGE = 50e6;

    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS; // 100 = 1%
    uint96 constant MIN_CHARGE_FEE = PayTypes.MIN_CHARGE_FEE; // 2_000 = $0.002

    uint96 internal tabBalance;

    function setUp() public {
        usdc = new MockUSDCV4();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTabV4(address(usdc), address(fee), feeWallet, relayerAddr);

        vm.prank(owner);
        fee.authorizeCaller(address(tab));

        usdc.mint(agent, 1_000_000e6);
        vm.prank(agent);
        usdc.approve(address(tab), type(uint256).max);

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, TAB_AMOUNT, MAX_CHARGE);
        tabBalance = tab.getTab(TAB_ID).amount;

        vm.warp(1773532800);
    }

    // =========================================================================
    // Fee floor: many small charges trigger floor
    // =========================================================================

    function test_feeFloor_manySmallCharges_withdrawCharged() public {
        // 50 charges of $0.01 each = $0.50 total
        // 1% of $0.50 = $0.005 (5_000)
        // Floor: 50 * $0.002 = $0.10 (100_000)
        // Floor wins: fee should be $0.10
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 50; i++) {
            tab.chargeTab(TAB_ID, 10_000); // $0.01
        }
        vm.stopPrank();

        uint96 unwithdrawn = 500_000; // $0.50
        uint96 expectedFloorFee = 50 * MIN_CHARGE_FEE; // $0.10
        uint96 expectedRateFee = uint96((uint256(unwithdrawn) * STANDARD_BPS) / 10_000); // $0.005

        // Floor must be higher
        assertGt(expectedFloorFee, expectedRateFee, "floor should exceed rate fee");

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(feeCollected, expectedFloorFee, "fee must equal floor fee");

        // Provider gets remainder
        uint96 expectedPayout = unwithdrawn - expectedFloorFee;
        assertEq(usdc.balanceOf(provider), expectedPayout);
    }

    function test_feeFloor_manySmallCharges_closeTab() public {
        // Same scenario but via closeTab
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 50; i++) {
            tab.chargeTab(TAB_ID, 10_000);
        }
        vm.stopPrank();

        uint96 unwithdrawn = 500_000;
        uint96 expectedFloorFee = 50 * MIN_CHARGE_FEE;

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(feeCollected, expectedFloorFee, "close fee must equal floor fee");
    }

    // =========================================================================
    // Fee floor: large charges — rate wins over floor
    // =========================================================================

    function test_feeFloor_largeCharges_rateWins() public {
        // 3 charges of $10 each = $30 total
        // 1% of $30 = $0.30 (300_000)
        // Floor: 3 * $0.002 = $0.006 (6_000)
        // Rate wins: fee should be $0.30
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();

        uint96 unwithdrawn = 30e6;
        uint96 expectedRateFee = uint96((uint256(unwithdrawn) * STANDARD_BPS) / 10_000);
        uint96 expectedFloorFee = 3 * MIN_CHARGE_FEE;

        assertGt(expectedRateFee, expectedFloorFee, "rate should exceed floor");

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(feeCollected, expectedRateFee, "fee must equal rate fee when rate > floor");
    }

    // =========================================================================
    // Fee floor: exactly at boundary ($0.20/charge = 1% equals floor)
    // =========================================================================

    function test_feeFloor_exactBoundary() public {
        // At $0.20/charge: 1% = $0.002 = MIN_CHARGE_FEE. Both equal.
        // 10 charges of $0.20 = $2.00
        // 1% of $2.00 = $0.02 (20_000)
        // Floor: 10 * $0.002 = $0.02 (20_000)
        // Equal — either path produces same fee
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 10; i++) {
            tab.chargeTab(TAB_ID, 200_000); // $0.20
        }
        vm.stopPrank();

        uint96 unwithdrawn = 2_000_000;
        uint96 expectedFee = 10 * MIN_CHARGE_FEE; // same as 1% of $2.00

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(feeCollected, expectedFee);
    }

    // =========================================================================
    // Fee floor capped at unwithdrawn (extreme micropayments)
    // =========================================================================

    function test_feeFloor_cappedAtUnwithdrawn() public {
        // 100 charges of $0.001 each = $0.10 total
        // 1% of $0.10 = $0.001 (1_000)
        // Floor: 100 * $0.002 = $0.20 (200_000)
        // Floor exceeds unwithdrawn ($0.10)! Cap at $0.10.
        // Provider gets $0, fee wallet gets entire $0.10.
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 100; i++) {
            tab.chargeTab(TAB_ID, 1_000); // $0.001
        }
        vm.stopPrank();

        uint96 unwithdrawn = 100_000; // $0.10 (exactly MIN_WITHDRAW_AMOUNT)
        uint96 floorFee = 100 * MIN_CHARGE_FEE; // $0.20
        assertGt(floorFee, unwithdrawn, "floor exceeds unwithdrawn - cap should kick in");

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(feeCollected, unwithdrawn, "fee capped at unwithdrawn");

        // Provider gets nothing (fee ate everything)
        assertEq(usdc.balanceOf(provider), 0, "provider gets 0 when floor > unwithdrawn");
    }

    // =========================================================================
    // chargeCountAtLastWithdrawal tracks across multiple withdrawals
    // =========================================================================

    function test_feeFloor_multipleWithdrawals_chargeCountTracked() public {
        // Round 1: 20 charges of $0.05 = $1.00
        // Floor: 20 * $0.002 = $0.04, Rate: 1% of $1.00 = $0.01 → floor wins
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 20; i++) {
            tab.chargeTab(TAB_ID, 50_000); // $0.05
        }
        vm.stopPrank();

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 expectedFee1 = 20 * MIN_CHARGE_FEE; // $0.04
        uint256 fee1 = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(fee1, expectedFee1, "first withdrawal: floor fee");

        // Round 2: 10 more charges of $0.05 = $0.50
        // Floor: 10 * $0.002 = $0.02, Rate: 1% of $0.50 = $0.005 → floor wins
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 10; i++) {
            tab.chargeTab(TAB_ID, 50_000);
        }
        vm.stopPrank();

        feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 expectedFee2 = 10 * MIN_CHARGE_FEE; // $0.02 (NOT 30 * $0.002)
        uint256 fee2 = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(fee2, expectedFee2, "second withdrawal: floor uses only new charges");
    }

    // =========================================================================
    // closeTab after withdrawal uses correct chargesNew delta
    // =========================================================================

    function test_feeFloor_closeAfterWithdrawal_correctDelta() public {
        // Withdraw after 20 small charges, then 5 more, then close
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 20; i++) {
            tab.chargeTab(TAB_ID, 10_000); // $0.01
        }
        vm.stopPrank();

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID); // withdraws $0.20, floor = 20 * $0.002 = $0.04

        // 5 more charges
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 5; i++) {
            tab.chargeTab(TAB_ID, 10_000);
        }
        vm.stopPrank();

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        // Close should only apply floor for 5 new charges, not 25 total
        // unwithdrawn at close = $0.05, floor = 5 * $0.002 = $0.01, rate = 1% of $0.05 = $0.0005
        uint96 expectedCloseFee = 5 * MIN_CHARGE_FEE; // $0.01
        uint256 closeFee = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(closeFee, expectedCloseFee, "close fee uses delta charges only");
    }

    // =========================================================================
    // settleCharges works the same as V3
    // =========================================================================

    function test_settleCharges_worksWithFeeFloor() public {
        // Use batch settlement, then withdraw with floor
        vm.prank(relayerAddr);
        tab.settleCharges(TAB_ID, 500_000, 50, 10_000); // $0.50, 50 charges, max $0.01

        uint96 unwithdrawn = 500_000;
        uint96 expectedFloorFee = 50 * MIN_CHARGE_FEE; // $0.10

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;
        assertEq(feeCollected, expectedFloorFee, "settle + withdraw: floor applied");
    }

    // =========================================================================
    // USDC conservation through full V4 lifecycle
    // =========================================================================

    function test_feeFloor_usdcConserved_fullLifecycle() public {
        // Charge, withdraw, charge more, close — all USDC accounted for
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 30; i++) {
            tab.chargeTab(TAB_ID, 10_000); // $0.01 each
        }
        vm.stopPrank();

        uint256 totalBefore =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        // 20 more charges
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 20; i++) {
            tab.chargeTab(TAB_ID, 10_000);
        }
        vm.stopPrank();

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint256 totalAfter =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        assertEq(totalAfter, totalBefore, "USDC conserved through withdraw + close with floor");
        assertEq(usdc.balanceOf(address(tab)), 0, "contract empty after close");
    }

    // =========================================================================
    // V3 compatibility: basic withdraw/close still work
    // =========================================================================

    function test_basicWithdraw_sameAsV3() public {
        // Standard large charges — V4 should behave identically to V3
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();

        uint96 charged = 30e6;
        uint96 expectedFee = uint96((uint256(charged) * STANDARD_BPS) / 10_000);
        uint96 expectedPayout = charged - expectedFee;

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        assertEq(usdc.balanceOf(provider), expectedPayout);
    }

    function test_basicClose_sameAsV3() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 30e6);

        uint96 charged = 30e6;
        uint96 expectedFee = uint96((uint256(charged) * STANDARD_BPS) / 10_000);

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint256 providerGain = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGain = usdc.balanceOf(feeWallet) - feeWalletBefore;
        uint256 agentGain = usdc.balanceOf(agent) - agentBefore;

        assertEq(feeGain, expectedFee);
        assertEq(providerGain, charged - expectedFee);
        assertEq(providerGain + feeGain + agentGain, tabBalance, "distribution sums to tab balance");
    }

    // =========================================================================
    // Access control unchanged from V3
    // =========================================================================

    function test_withdrawCharged_onlyRelayer() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 5e6);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, provider));
        vm.prank(provider);
        tab.withdrawCharged(TAB_ID);
    }

    function test_closeTab_anyParty() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 1e6);

        // Agent can close
        vm.prank(agent);
        tab.closeTab(TAB_ID);

        assertEq(uint8(tab.getTab(TAB_ID).status), uint8(PayTypes.TabStatus.Closed));
    }

    // =========================================================================
    // MIN_WITHDRAW_AMOUNT = $0.10 (from V3)
    // =========================================================================

    function test_withdrawCharged_belowMinimum() public {
        // Charge $0.05 — below $0.10 minimum
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 50_000);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, 50_000, PayTypes.MIN_WITHDRAW_AMOUNT));
        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);
    }
}

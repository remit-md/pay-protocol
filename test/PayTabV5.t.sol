// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTabV5} from "../src/PayTabV5.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDCV5
contract MockUSDCV5 {
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

/// @title PayTabV5Test
/// @notice Unit tests for PayTabV5 gas optimizations: fee accumulation, transient reentrancy, packed struct.
contract PayTabV5Test is Test {
    PayTabV5 internal tab;
    PayFee internal fee;
    MockUSDCV5 internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayerAddr = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    bytes32 constant TAB_ID = bytes32("tab-v5-001");
    uint96 constant TAB_AMOUNT = 100e6; // $100
    uint96 constant MAX_CHARGE = 50e6;

    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS;
    uint96 constant MIN_CHARGE_FEE = PayTypes.MIN_CHARGE_FEE;

    uint96 internal tabBalance;

    function setUp() public {
        usdc = new MockUSDCV5();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTabV5(address(usdc), address(fee), feeWallet, relayerAddr);

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
    // Fee accumulation: openTab
    // =========================================================================

    function test_openTab_feesAccumulated() public {
        // Opening the tab in setUp should have accumulated the activation fee
        uint96 activationFee = TAB_AMOUNT / 100; // 1% of $100 = $1.00
        assertEq(tab.accumulatedFees(), activationFee, "activation fee accumulated");
        // feeWallet should NOT have received anything yet
        assertEq(usdc.balanceOf(feeWallet), 0, "feeWallet empty before sweep");
    }

    function test_openTab_singleTransferFrom() public {
        // Contract should hold tabBalance (amount - activationFee) + activationFee = full amount
        // But the contract balance includes the activation fee since it's accumulated
        uint96 activationFee = TAB_AMOUNT / 100;
        uint96 expectedContractBalance = (TAB_AMOUNT - activationFee) + activationFee;
        assertEq(usdc.balanceOf(address(tab)), expectedContractBalance, "contract holds full amount");
    }

    // =========================================================================
    // Fee accumulation: withdrawCharged
    // =========================================================================

    function test_withdrawCharged_feeAccumulated_notTransferred() public {
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();

        uint96 charged = 30e6;
        uint96 expectedFee = uint96((uint256(charged) * STANDARD_BPS) / 10_000);
        uint96 expectedPayout = charged - expectedFee;

        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        // Provider gets payout directly
        assertEq(usdc.balanceOf(provider), expectedPayout, "provider received payout");
        // Fee accumulated, NOT transferred to feeWallet
        assertEq(usdc.balanceOf(feeWallet), 0, "feeWallet still empty");
        assertEq(tab.accumulatedFees(), feesBefore + expectedFee, "fee accumulated");
    }

    // =========================================================================
    // Fee accumulation: closeTab
    // =========================================================================

    function test_closeTab_feeAccumulated() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 30e6);

        uint96 charged = 30e6;
        uint96 expectedFee = uint96((uint256(charged) * STANDARD_BPS) / 10_000);

        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        // feeWallet still empty — fee accumulated
        assertEq(usdc.balanceOf(feeWallet), 0, "feeWallet empty after close");
        assertEq(tab.accumulatedFees(), feesBefore + expectedFee, "fee accumulated on close");
    }

    // =========================================================================
    // sweepFees
    // =========================================================================

    function test_sweepFees_transfersToFeeWallet() public {
        // Activation fee already accumulated from setUp
        uint96 activationFee = TAB_AMOUNT / 100;
        assertEq(tab.accumulatedFees(), activationFee);

        tab.sweepFees();

        assertEq(usdc.balanceOf(feeWallet), activationFee, "feeWallet received sweep");
        assertEq(tab.accumulatedFees(), 0, "accumulated reset to 0");
    }

    function test_sweepFees_revertsWhenZero() public {
        // Sweep the activation fee first
        tab.sweepFees();

        // Second sweep should revert
        vm.expectRevert(PayErrors.ZeroAmount.selector);
        tab.sweepFees();
    }

    function test_sweepFees_permissionless() public {
        // Anyone can call sweepFees
        address random = makeAddr("random");
        vm.prank(random);
        tab.sweepFees();

        assertEq(usdc.balanceOf(feeWallet), TAB_AMOUNT / 100);
    }

    function test_sweepFees_afterMultipleOps() public {
        // Open + withdraw + close = 3 fee accumulations
        uint96 activationFee = TAB_AMOUNT / 100; // from setUp open

        // Charge and withdraw
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();
        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 charged1 = 20e6;
        uint96 withdrawFee = uint96((uint256(charged1) * STANDARD_BPS) / 10_000);

        // More charges then close
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 5e6);
        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint96 charged2 = 5e6;
        // 1 new charge since withdraw, rate fee = 1% of $5 = $0.05, floor = 1 * $0.002 = $0.002
        uint96 closeFee = uint96((uint256(charged2) * STANDARD_BPS) / 10_000);

        uint96 totalFees = activationFee + withdrawFee + closeFee;
        assertEq(tab.accumulatedFees(), totalFees, "all fees accumulated");

        tab.sweepFees();
        assertEq(usdc.balanceOf(feeWallet), totalFees, "all fees swept");
    }

    // =========================================================================
    // Fee floor: same behavior as V4
    // =========================================================================

    function test_feeFloor_manySmallCharges() public {
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 50; i++) {
            tab.chargeTab(TAB_ID, 10_000); // $0.01
        }
        vm.stopPrank();

        uint96 unwithdrawn = 500_000;
        uint96 expectedFloorFee = 50 * MIN_CHARGE_FEE; // $0.10
        uint96 expectedRateFee = uint96((uint256(unwithdrawn) * STANDARD_BPS) / 10_000);
        assertGt(expectedFloorFee, expectedRateFee, "floor exceeds rate");

        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 feeAccumulated = tab.accumulatedFees() - feesBefore;
        assertEq(feeAccumulated, expectedFloorFee, "floor fee applied");
    }

    function test_feeFloor_largeCharges_rateWins() public {
        vm.startPrank(relayerAddr);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        tab.chargeTab(TAB_ID, 10e6);
        vm.stopPrank();

        uint96 unwithdrawn = 30e6;
        uint96 expectedRateFee = uint96((uint256(unwithdrawn) * STANDARD_BPS) / 10_000);

        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 feeAccumulated = tab.accumulatedFees() - feesBefore;
        assertEq(feeAccumulated, expectedRateFee, "rate fee when rate > floor");
    }

    function test_feeFloor_cappedAtUnwithdrawn() public {
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 100; i++) {
            tab.chargeTab(TAB_ID, 1_000); // $0.001
        }
        vm.stopPrank();

        uint96 unwithdrawn = 100_000; // $0.10
        uint96 floorFee = 100 * MIN_CHARGE_FEE; // $0.20
        assertGt(floorFee, unwithdrawn, "floor exceeds unwithdrawn");

        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 feeAccumulated = tab.accumulatedFees() - feesBefore;
        assertEq(feeAccumulated, unwithdrawn, "fee capped at unwithdrawn");
        assertEq(usdc.balanceOf(provider), 0, "provider gets 0");
    }

    // =========================================================================
    // Multi-withdrawal charge count tracking (V5 struct-packed)
    // =========================================================================

    function test_multipleWithdrawals_chargeCountTracked() public {
        // Round 1: 20 charges
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 20; i++) {
            tab.chargeTab(TAB_ID, 50_000); // $0.05
        }
        vm.stopPrank();

        uint96 feesBefore = tab.accumulatedFees();
        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 fee1 = tab.accumulatedFees() - feesBefore;
        uint96 expectedFee1 = 20 * MIN_CHARGE_FEE; // floor wins
        assertEq(fee1, expectedFee1, "round 1: floor fee");

        // Round 2: 10 more charges — should count only new charges
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 10; i++) {
            tab.chargeTab(TAB_ID, 50_000);
        }
        vm.stopPrank();

        feesBefore = tab.accumulatedFees();
        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 fee2 = tab.accumulatedFees() - feesBefore;
        uint96 expectedFee2 = 10 * MIN_CHARGE_FEE; // 10 new charges, NOT 30
        assertEq(fee2, expectedFee2, "round 2: only new charges counted");
    }

    function test_closeAfterWithdrawal_correctDelta() public {
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 20; i++) {
            tab.chargeTab(TAB_ID, 10_000);
        }
        vm.stopPrank();

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        // 5 more charges
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 5; i++) {
            tab.chargeTab(TAB_ID, 10_000);
        }
        vm.stopPrank();

        uint96 feesBefore = tab.accumulatedFees();
        vm.prank(agent);
        tab.closeTab(TAB_ID);

        uint96 closeFee = tab.accumulatedFees() - feesBefore;
        uint96 expectedCloseFee = 5 * MIN_CHARGE_FEE; // 5 new charges
        assertEq(closeFee, expectedCloseFee, "close fee uses delta charges only");
    }

    // =========================================================================
    // settleCharges works with V5
    // =========================================================================

    function test_settleCharges_worksWithFeeFloor() public {
        vm.prank(relayerAddr);
        tab.settleCharges(TAB_ID, 500_000, 50, 10_000);

        uint96 expectedFloorFee = 50 * MIN_CHARGE_FEE;
        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        uint96 feeAccumulated = tab.accumulatedFees() - feesBefore;
        assertEq(feeAccumulated, expectedFloorFee, "settle + withdraw: floor applied");
    }

    // =========================================================================
    // USDC conservation: full lifecycle
    // =========================================================================

    function test_usdcConserved_fullLifecycle() public {
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 30; i++) {
            tab.chargeTab(TAB_ID, 10_000);
        }
        vm.stopPrank();

        uint256 totalBefore =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);

        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < 20; i++) {
            tab.chargeTab(TAB_ID, 10_000);
        }
        vm.stopPrank();

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        // Sweep all accumulated fees
        tab.sweepFees();

        uint256 totalAfter =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        assertEq(totalAfter, totalBefore, "USDC conserved through full lifecycle");
        assertEq(usdc.balanceOf(address(tab)), 0, "contract empty after close + sweep");
    }

    // =========================================================================
    // getTab returns V4-compatible struct
    // =========================================================================

    function test_getTab_returnsV4CompatibleStruct() public view {
        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.agent, agent);
        assertEq(t.provider, provider);
        assertEq(t.maxChargePerCall, MAX_CHARGE);
        assertEq(uint8(t.status), uint8(PayTypes.TabStatus.Active));
    }

    function test_getTabV5_returnsFullStruct() public view {
        PayTypes.TabV5 memory t = tab.getTabV5(TAB_ID);
        assertEq(t.agent, agent);
        assertEq(t.provider, provider);
        assertEq(t.chargeCountAtLastWithdraw, 0);
    }

    // =========================================================================
    // Access control unchanged
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

        vm.prank(agent);
        tab.closeTab(TAB_ID);

        assertEq(uint8(tab.getTab(TAB_ID).status), uint8(PayTypes.TabStatus.Closed));
    }

    function test_withdrawCharged_belowMinimum() public {
        vm.prank(relayerAddr);
        tab.chargeTab(TAB_ID, 50_000);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, 50_000, PayTypes.MIN_WITHDRAW_AMOUNT));
        vm.prank(relayerAddr);
        tab.withdrawCharged(TAB_ID);
    }

    // =========================================================================
    // Constructor validation
    // =========================================================================

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert(PayErrors.ZeroAddress.selector);
        new PayTabV5(address(0), address(fee), feeWallet, relayerAddr);

        vm.expectRevert(PayErrors.ZeroAddress.selector);
        new PayTabV5(address(usdc), address(0), feeWallet, relayerAddr);

        vm.expectRevert(PayErrors.ZeroAddress.selector);
        new PayTabV5(address(usdc), address(fee), address(0), relayerAddr);

        vm.expectRevert(PayErrors.ZeroAddress.selector);
        new PayTabV5(address(usdc), address(fee), feeWallet, address(0));
    }
}

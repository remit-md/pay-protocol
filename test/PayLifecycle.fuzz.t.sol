// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCLifecycle
/// @notice Minimal ERC-20 mock for lifecycle fuzz testing.
contract MockUSDCLifecycle {
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

/// @title PayLifecycleFuzzTest
/// @notice End-to-end fuzz tests exercising the full tab lifecycle (open → charge × N → topup → charge → close)
///         and cross-cutting numeric edge cases across all contracts.
contract PayLifecycleFuzzTest is Test {
    PayTab internal payTab;
    PayFee internal fee;
    MockUSDCLifecycle internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    uint96 constant MIN_TAB = PayTypes.MIN_TAB_AMOUNT;
    uint96 constant MIN_ACT_FEE = PayTypes.MIN_ACTIVATION_FEE;

    function setUp() public {
        usdc = new MockUSDCLifecycle();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        payTab = new PayTab(address(usdc), address(fee), feeWallet, relayer);

        vm.prank(owner);
        fee.authorizeCaller(address(payTab));

        // Warp to 2026-03-15
        vm.warp(1773532800);
    }

    // =========================================================================
    // Full lifecycle: open → charge × N → close
    // =========================================================================

    /// @notice USDC is fully conserved across the entire tab lifecycle.
    ///         agent_loss == provider_payout + fee_total + activation_fee (always, no dust).
    function testFuzz_fullLifecycle_usdcConserved(uint96 tabAmount, uint96 maxCharge, uint8 numCharges) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));
        maxCharge = uint96(bound(maxCharge, 1, tabAmount));
        numCharges = uint8(bound(numCharges, 1, 20));

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        uint256 totalBefore = usdc.balanceOf(agent) + usdc.balanceOf(address(payTab)) + usdc.balanceOf(feeWallet)
            + usdc.balanceOf(provider);

        // Open
        bytes32 tabId = bytes32("lifecycle");
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, maxCharge);

        uint96 balance = payTab.getTab(tabId).amount;
        uint96 safeCharge = uint96(balance / numCharges);
        if (safeCharge > maxCharge) safeCharge = maxCharge;

        // Charge N times
        if (safeCharge > 0) {
            vm.startPrank(relayer);
            for (uint8 i = 0; i < numCharges; i++) {
                if (payTab.getTab(tabId).amount < safeCharge) break;
                payTab.chargeTab(tabId, safeCharge);
            }
            vm.stopPrank();
        }

        // Close
        vm.prank(agent);
        payTab.closeTab(tabId);

        uint256 totalAfter = usdc.balanceOf(agent) + usdc.balanceOf(address(payTab)) + usdc.balanceOf(feeWallet)
            + usdc.balanceOf(provider);

        assertEq(totalAfter, totalBefore, "USDC must be conserved across full lifecycle");
    }

    // =========================================================================
    // Full lifecycle with top-up: open → charge → topup → charge → close
    // =========================================================================

    /// @notice USDC is conserved even with top-ups mid-lifecycle.
    function testFuzz_lifecycleWithTopUp_usdcConserved(
        uint96 tabAmount,
        uint96 maxCharge,
        uint96 topUpAmount,
        uint96 charge1,
        uint96 charge2
    ) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        maxCharge = uint96(bound(maxCharge, 1, tabAmount));
        topUpAmount = uint96(bound(topUpAmount, 1, 500_000e6));

        usdc.mint(agent, uint256(tabAmount) + uint256(topUpAmount));
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        uint256 totalBefore = usdc.balanceOf(agent) + usdc.balanceOf(address(payTab)) + usdc.balanceOf(feeWallet)
            + usdc.balanceOf(provider);

        // Open
        bytes32 tabId = bytes32("topup-lc");
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, maxCharge);

        // Charge 1
        uint96 bal = payTab.getTab(tabId).amount;
        charge1 = uint96(bound(charge1, 1, bal < maxCharge ? bal : maxCharge));
        vm.prank(relayer);
        payTab.chargeTab(tabId, charge1);

        // Top up
        vm.prank(agent);
        payTab.topUpTab(tabId, topUpAmount);

        // Charge 2
        bal = payTab.getTab(tabId).amount;
        if (bal > 0) {
            charge2 = uint96(bound(charge2, 1, bal < maxCharge ? bal : maxCharge));
            vm.prank(relayer);
            payTab.chargeTab(tabId, charge2);
        }

        // Close
        vm.prank(agent);
        payTab.closeTab(tabId);

        uint256 totalAfter = usdc.balanceOf(agent) + usdc.balanceOf(address(payTab)) + usdc.balanceOf(feeWallet)
            + usdc.balanceOf(provider);

        assertEq(totalAfter, totalBefore, "USDC must be conserved with top-up in lifecycle");
    }

    // =========================================================================
    // Lifecycle: provider + fee + refund == total locked
    // =========================================================================

    /// @notice At close, provider_payout + fee + agent_refund == (balance at open + top-ups).
    function testFuzz_closeDistribution_sumsCorrectly(uint96 tabAmount, uint96 charge) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        bytes32 tabId = bytes32("dist");
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;
        charge = uint96(bound(charge, 1, balance));

        vm.prank(relayer);
        payTab.chargeTab(tabId, charge);

        uint96 remaining = payTab.getTab(tabId).amount;
        uint96 totalCharged = payTab.getTab(tabId).totalCharged;

        // Snapshot before close
        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeWallet);
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        payTab.closeTab(tabId);

        uint256 providerGot = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGot = usdc.balanceOf(feeWallet) - feeBefore;
        uint256 agentGot = usdc.balanceOf(agent) - agentBefore;

        // Provider + fee should equal totalCharged
        assertEq(providerGot + feeGot, totalCharged, "provider + fee must equal totalCharged");
        // Agent gets remaining
        assertEq(agentGot, remaining, "agent must get remaining balance");
    }

    // =========================================================================
    // Activation fee crossover edge case
    // =========================================================================

    /// @notice At exactly $10 (10_000_000), amount/100 == MIN_ACTIVATION_FEE ($0.10).
    ///         Below $10: fee == MIN. At/above $10: fee == amount/100. Verify crossover.
    function testFuzz_activationFee_crossover(uint96 tabAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 20e6)); // $5 - $20 range around crossover

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        bytes32 tabId = keccak256(abi.encode(tabAmount));
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, 1);

        PayTypes.Tab memory t = payTab.getTab(tabId);

        uint96 percentFee = tabAmount / 100;
        uint96 expectedFee = percentFee > MIN_ACT_FEE ? percentFee : MIN_ACT_FEE;

        assertEq(t.activationFee, expectedFee, "activation fee must follow max(MIN, 1%)");
        assertEq(t.amount + t.activationFee, tabAmount, "balance + activation fee must equal original amount");
    }

    // =========================================================================
    // Fee rounding on odd amounts
    // =========================================================================

    /// @notice Processing fee on close: truncation must not create dust.
    ///         provider_payout + fee must always equal totalCharged.
    function testFuzz_closeFee_noTruncationDust(uint96 tabAmount, uint96 charge) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        bytes32 tabId = bytes32("trunc");
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;
        charge = uint96(bound(charge, 1, balance));

        vm.prank(relayer);
        payTab.chargeTab(tabId, charge);

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeWallet);

        vm.prank(agent);
        payTab.closeTab(tabId);

        uint256 providerGot = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGot = usdc.balanceOf(feeWallet) - feeBefore;

        // No dust: provider + fee == totalCharged exactly
        assertEq(providerGot + feeGot, charge, "no truncation dust allowed");
    }

    // =========================================================================
    // Drain tab to zero then close
    // =========================================================================

    /// @notice Tab charged to exactly zero: agent gets nothing back, no revert.
    function testFuzz_drainToZero_closeSafe(uint96 tabAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        bytes32 tabId = bytes32("drain");
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;

        // Drain fully
        vm.prank(relayer);
        payTab.chargeTab(tabId, balance);

        assertEq(payTab.getTab(tabId).amount, 0, "balance must be zero after full drain");

        // Close should work — agent gets $0 refund
        uint256 agentBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        payTab.closeTab(tabId);

        assertEq(usdc.balanceOf(agent), agentBefore, "agent must get zero refund on fully drained tab");
    }

    // =========================================================================
    // Multiple small charges then close: accumulated fee
    // =========================================================================

    /// @notice Many small charges accumulate totalCharged; close fee is on the total.
    function testFuzz_manySmallCharges_closeFeeOnTotal(uint96 tabAmount, uint96 chargeSize, uint8 numCharges) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 100_000e6));
        numCharges = uint8(bound(numCharges, 2, 50));

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        bytes32 tabId = bytes32("many");
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = payTab.getTab(tabId).amount;
        chargeSize = uint96(bound(chargeSize, 1, balance / numCharges));
        if (chargeSize == 0) return;

        vm.startPrank(relayer);
        for (uint8 i = 0; i < numCharges; i++) {
            if (payTab.getTab(tabId).amount < chargeSize) break;
            payTab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        uint96 totalCharged = payTab.getTab(tabId).totalCharged;

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeWallet);

        vm.prank(agent);
        payTab.closeTab(tabId);

        uint256 providerGot = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGot = usdc.balanceOf(feeWallet) - feeBefore;

        // Fee is on total, not per-charge
        assertEq(providerGot + feeGot, totalCharged, "close fee must be on cumulative totalCharged");
        // Fee can be zero for tiny totalCharged (< 100 units) due to integer division truncation.
        // This is valid: closeTab uses getFeeRate directly, not calculateFee (which has ZeroFee check).
        if (totalCharged >= 100) {
            assertGt(feeGot, 0, "fee must be positive when totalCharged >= 100");
        }
    }

    // =========================================================================
    // Zero-charge close: no fee, full refund
    // =========================================================================

    /// @notice Tab opened but never charged: close refunds entire balance, zero fee.
    function testFuzz_uncharged_fullRefund(uint96 tabAmount) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        usdc.mint(agent, tabAmount);
        vm.prank(agent);
        usdc.approve(address(payTab), type(uint256).max);

        bytes32 tabId = bytes32("uncharge");
        vm.prank(agent);
        payTab.openTab(tabId, provider, tabAmount, 1);

        uint96 balance = payTab.getTab(tabId).amount;

        uint256 providerBefore = usdc.balanceOf(provider);
        uint256 feeBefore = usdc.balanceOf(feeWallet);

        vm.prank(agent);
        payTab.closeTab(tabId);

        // Provider gets nothing, fee wallet gets nothing from close
        assertEq(usdc.balanceOf(provider), providerBefore, "provider must get zero on uncharged close");
        assertEq(usdc.balanceOf(feeWallet), feeBefore, "feeWallet must not change on uncharged close");
        // Agent gets full balance back
        assertGe(usdc.balanceOf(agent), balance, "agent must get full balance back on uncharged close");
    }
}

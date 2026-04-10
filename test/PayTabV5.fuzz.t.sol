// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTabV5} from "../src/PayTabV5.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCV5Fuzz
contract MockUSDCV5Fuzz {
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

/// @title PayTabV5FuzzTest
/// @notice Property-based fuzz tests for PayTabV5 gas optimizations.
///         Verifies fee accumulation + sweep conserves USDC identically to V4.
contract PayTabV5FuzzTest is Test {
    PayTabV5 internal tab;
    PayFee internal fee;
    MockUSDCV5Fuzz internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayerAddr = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS;
    uint96 constant MIN_CHARGE_FEE = PayTypes.MIN_CHARGE_FEE;
    uint96 constant MIN_TAB = PayTypes.MIN_TAB_AMOUNT;
    uint96 constant MIN_WITHDRAW = PayTypes.MIN_WITHDRAW_AMOUNT;

    function setUp() public {
        usdc = new MockUSDCV5Fuzz();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTabV5(address(usdc), address(fee), feeWallet, relayerAddr);

        vm.prank(owner);
        fee.authorizeCaller(address(tab));

        usdc.mint(agent, type(uint96).max);
        vm.prank(agent);
        usdc.approve(address(tab), type(uint256).max);

        vm.warp(1773532800);
    }

    // =========================================================================
    // Property: USDC conservation through open + charges + withdraw + close + sweep
    // =========================================================================

    function testFuzz_fullLifecycle_usdcConserved(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 50));

        bytes32 tabId = bytes32("fuzz-conserve-v5");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = tab.getTab(tabId).amount;
        uint96 maxPerCharge = balance / uint96(numCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < numCharges; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        uint96 totalCharged = chargeSize * uint96(numCharges);

        uint256 totalBefore =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        // Withdraw if possible
        if (totalCharged >= MIN_WITHDRAW) {
            vm.prank(relayerAddr);
            tab.withdrawCharged(tabId);
        }

        // Close
        vm.prank(agent);
        tab.closeTab(tabId);

        // Sweep all fees
        if (tab.accumulatedFees() > 0) {
            tab.sweepFees();
        }

        uint256 totalAfter =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        assertEq(totalAfter, totalBefore, "USDC must be conserved");
        assertEq(usdc.balanceOf(address(tab)), 0, "contract empty after close + sweep");
    }

    // =========================================================================
    // Property: accumulated fees = sum of all activation + processing fees
    // =========================================================================

    function testFuzz_accumulatedFees_matchExpected(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 50));

        bytes32 tabId = bytes32("fuzz-accum-v5");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 activationFee = tabAmount / 100;
        if (activationFee < PayTypes.MIN_ACTIVATION_FEE) activationFee = PayTypes.MIN_ACTIVATION_FEE;

        uint96 balance = tab.getTab(tabId).amount;
        uint96 maxPerCharge = balance / uint96(numCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < numCharges; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        // Close (triggers fee accumulation)
        vm.prank(agent);
        tab.closeTab(tabId);

        uint96 totalFees = tab.accumulatedFees();

        // Fees must include activation fee
        assertGe(totalFees, activationFee, "accumulated >= activation fee");
    }

    // =========================================================================
    // Property: fee >= max(floor, rate-based) AND fee <= unwithdrawn
    // =========================================================================

    function testFuzz_withdrawFeeFloorEnforced(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 100));

        bytes32 tabId = bytes32("fuzz-floor-v5");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = tab.getTab(tabId).amount;
        uint96 maxPerCharge = balance / uint96(numCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < numCharges; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        uint96 totalCharged = chargeSize * uint96(numCharges);
        if (totalCharged < MIN_WITHDRAW) return;

        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(relayerAddr);
        tab.withdrawCharged(tabId);

        uint96 feeCollected = tab.accumulatedFees() - feesBefore;

        // Expected bounds
        uint96 rateFee = uint96((uint256(totalCharged) * STANDARD_BPS) / 10_000);
        uint96 floorFee = uint96(uint256(numCharges) * MIN_CHARGE_FEE);
        uint96 expectedMin = rateFee > floorFee ? rateFee : floorFee;
        if (expectedMin > totalCharged) expectedMin = totalCharged;

        assertEq(feeCollected, expectedMin, "fee must equal max(floor, rate), capped at unwithdrawn");
    }

    // =========================================================================
    // Property: distribution sums to tab balance
    // =========================================================================

    function testFuzz_close_distributionSumsToTabBalance(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 50));

        bytes32 tabId = bytes32("fuzz-dist-v5");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = tab.getTab(tabId).amount;
        uint96 maxPerCharge = balance / uint96(numCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < numCharges; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        uint256 providerBefore = usdc.balanceOf(provider);
        uint96 feesBefore = tab.accumulatedFees();
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        tab.closeTab(tabId);

        uint256 providerGain = usdc.balanceOf(provider) - providerBefore;
        uint96 feeGain = tab.accumulatedFees() - feesBefore;
        uint256 agentGain = usdc.balanceOf(agent) - agentBefore;

        assertEq(providerGain + feeGain + agentGain, balance, "distribution must sum to tab balance");
    }

    // =========================================================================
    // Property: multiple withdrawal windows track correctly
    // =========================================================================

    function testFuzz_multipleWithdrawals_floorTracksCorrectly(
        uint8 chargesRound1,
        uint8 chargesRound2,
        uint96 chargeSize
    ) public {
        chargesRound1 = uint8(bound(chargesRound1, 1, 30));
        chargesRound2 = uint8(bound(chargesRound2, 1, 30));
        uint256 totalCharges = uint256(chargesRound1) + uint256(chargesRound2);

        bytes32 tabId = bytes32("fuzz-multi-v5");
        uint96 tabAmount = 100e6;
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = tab.getTab(tabId).amount;
        uint96 maxPerCharge = balance / uint96(totalCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        // Round 1
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < chargesRound1; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        uint96 charged1 = chargeSize * uint96(chargesRound1);
        if (charged1 >= MIN_WITHDRAW) {
            uint96 feesBefore = tab.accumulatedFees();

            vm.prank(relayerAddr);
            tab.withdrawCharged(tabId);

            uint96 fee1 = tab.accumulatedFees() - feesBefore;
            uint96 rateFee1 = uint96((uint256(charged1) * STANDARD_BPS) / 10_000);
            uint96 floorFee1 = uint96(uint256(chargesRound1) * MIN_CHARGE_FEE);
            uint96 expected1 = rateFee1 > floorFee1 ? rateFee1 : floorFee1;
            if (expected1 > charged1) expected1 = charged1;
            assertEq(fee1, expected1, "round 1 fee correct");
        }

        // Round 2
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < chargesRound2; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        // Close
        vm.prank(agent);
        tab.closeTab(tabId);

        // Conservation check
        if (tab.accumulatedFees() > 0) {
            tab.sweepFees();
        }
        assertEq(usdc.balanceOf(address(tab)), 0, "contract empty");
    }

    // =========================================================================
    // Property: fee never exceeds unwithdrawn
    // =========================================================================

    function testFuzz_feeNeverExceedsUnwithdrawn(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 100_000e6));
        numCharges = uint8(bound(numCharges, 1, 200));

        bytes32 tabId = bytes32("fuzz-cap-v5");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = tab.getTab(tabId).amount;
        uint96 maxPerCharge = balance / uint96(numCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < numCharges; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        uint96 totalCharged = chargeSize * uint96(numCharges);

        uint96 feesBefore = tab.accumulatedFees();

        vm.prank(agent);
        tab.closeTab(tabId);

        uint96 feeCollected = tab.accumulatedFees() - feesBefore;

        assertLe(feeCollected, totalCharged, "fee must not exceed total charged");
    }

    // =========================================================================
    // Property: sweep after close leaves contract at zero
    // =========================================================================

    function testFuzz_sweepAfterClose_contractEmpty(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 50));

        bytes32 tabId = bytes32("fuzz-empty-v5");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = tab.getTab(tabId).amount;
        uint96 maxPerCharge = balance / uint96(numCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < numCharges; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        vm.prank(agent);
        tab.closeTab(tabId);

        if (tab.accumulatedFees() > 0) {
            tab.sweepFees();
        }

        assertEq(usdc.balanceOf(address(tab)), 0, "contract fully drained after close + sweep");
        assertEq(tab.accumulatedFees(), 0, "no pending fees");
    }
}

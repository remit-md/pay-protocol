// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title PayFeeHandler
/// @notice Handler for invariant testing PayFee. Records transactions and advances time.
contract PayFeeHandler is Test {
    PayFee public payFee;

    address public providerA = makeAddr("providerA");
    address public providerB = makeAddr("providerB");

    // Ghost variables
    uint256 public totalRecordedA;
    uint256 public totalRecordedB;
    uint256 public recordCalls;

    constructor(PayFee payFee_) {
        payFee = payFee_;
    }

    /// @dev Record a transaction for provider A.
    function recordForA(uint96 amount) external {
        amount = uint96(bound(amount, PayTypes.MIN_DIRECT_AMOUNT, 100_000e6));
        payFee.recordTransaction(providerA, amount);
        totalRecordedA += amount;
        recordCalls++;
    }

    /// @dev Record a transaction for provider B.
    function recordForB(uint96 amount) external {
        amount = uint96(bound(amount, PayTypes.MIN_DIRECT_AMOUNT, 100_000e6));
        payFee.recordTransaction(providerB, amount);
        totalRecordedB += amount;
        recordCalls++;
    }

    /// @dev Advance time by up to 35 days (to test month boundary resets).
    function advanceTime(uint256 delta) external {
        delta = bound(delta, 0, 35 days);
        vm.warp(block.timestamp + delta);
        // If we crossed a month, ghost vars are stale. Reset them when we detect a reset.
        if (payFee.getMonthlyVolume(providerA) == 0) totalRecordedA = 0;
        if (payFee.getMonthlyVolume(providerB) == 0) totalRecordedB = 0;
    }
}

/// @title PayFeeInvariantTest
/// @notice Invariant tests for PayFee safety properties.
contract PayFeeInvariantTest is Test {
    PayFee internal fee;
    PayFeeHandler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        handler = new PayFeeHandler(fee);

        // Authorize handler to record transactions
        vm.prank(owner);
        fee.authorizeCaller(address(handler));

        // Warp to 2026-03-15
        vm.warp(1773532800);

        targetContract(address(handler));
    }

    // =========================================================================
    // Invariant: fee is always <= 1% of amount (standard rate cap)
    // =========================================================================

    /// @notice calculateFee must never return a fee exceeding the standard rate (100 bps).
    function invariant_fee_neverExceedsStandardRate() public view {
        address provA = handler.providerA();
        address provB = handler.providerB();

        // Test with a reference amount
        uint96 testAmount = 10_000e6; // $10k

        uint96 feeA = fee.calculateFee(provA, testAmount);
        uint96 feeB = fee.calculateFee(provB, testAmount);

        uint96 maxFee = uint96((uint256(testAmount) * PayTypes.FEE_RATE_BPS) / 10_000);

        assertLe(feeA, maxFee, "invariant: fee A <= standard rate cap");
        assertLe(feeB, maxFee, "invariant: fee B <= standard rate cap");
    }

    // =========================================================================
    // Invariant: fee rate is always either standard or preferred (no other value)
    // =========================================================================

    /// @notice getFeeRate must return exactly FEE_RATE_BPS or FEE_RATE_PREFERRED_BPS.
    function invariant_feeRate_isStandardOrPreferred() public view {
        address provA = handler.providerA();
        address provB = handler.providerB();

        uint96 rateA = fee.getFeeRate(provA);
        uint96 rateB = fee.getFeeRate(provB);

        assertTrue(
            rateA == PayTypes.FEE_RATE_BPS || rateA == PayTypes.FEE_RATE_PREFERRED_BPS,
            "invariant: rate A must be standard or preferred"
        );
        assertTrue(
            rateB == PayTypes.FEE_RATE_BPS || rateB == PayTypes.FEE_RATE_PREFERRED_BPS,
            "invariant: rate B must be standard or preferred"
        );
    }

    // =========================================================================
    // Invariant: volume tracking matches ghost state
    // =========================================================================

    /// @notice Monthly volume must equal our ghost-tracked total (within the same month).
    function invariant_volume_matchesGhost() public view {
        address provA = handler.providerA();
        address provB = handler.providerB();

        assertEq(fee.getMonthlyVolume(provA), handler.totalRecordedA(), "invariant: volume A matches ghost");
        assertEq(fee.getMonthlyVolume(provB), handler.totalRecordedB(), "invariant: volume B matches ghost");
    }

    // =========================================================================
    // Invariant: provider isolation — volume for A never affects B
    // =========================================================================

    /// @notice Fee rate for provider A must be independent of provider B's volume.
    function invariant_providerIsolation() public view {
        address provA = handler.providerA();
        address provB = handler.providerB();

        uint256 volA = fee.getMonthlyVolume(provA);
        uint256 volB = fee.getMonthlyVolume(provB);
        uint96 rateA = fee.getFeeRate(provA);
        uint96 rateB = fee.getFeeRate(provB);

        // If A is below threshold, A must have standard rate regardless of B
        if (volA < PayTypes.FEE_THRESHOLD) {
            assertEq(rateA, PayTypes.FEE_RATE_BPS, "invariant: A below threshold => standard rate");
        }
        // If A is at/above threshold, A must have preferred rate regardless of B
        if (volA >= PayTypes.FEE_THRESHOLD) {
            assertEq(rateA, PayTypes.FEE_RATE_PREFERRED_BPS, "invariant: A above threshold => preferred rate");
        }
        // Same for B
        if (volB < PayTypes.FEE_THRESHOLD) {
            assertEq(rateB, PayTypes.FEE_RATE_BPS, "invariant: B below threshold => standard rate");
        }
        if (volB >= PayTypes.FEE_THRESHOLD) {
            assertEq(rateB, PayTypes.FEE_RATE_PREFERRED_BPS, "invariant: B above threshold => preferred rate");
        }
    }
}

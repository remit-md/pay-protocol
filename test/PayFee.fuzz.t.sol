// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title PayFeeFuzzTest
/// @notice Property-based fuzz tests for PayFee
contract PayFeeFuzzTest is Test {
    PayFee internal fee;

    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("caller");

    function setUp() public {
        PayFee impl = new PayFee();
        bytes memory data = abi.encodeCall(impl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(impl), data)));

        vm.prank(owner);
        fee.authorizeCaller(caller);

        // Warp to a known date: 2026-03-15 00:00:00 UTC
        vm.warp(1773532800);
    }

    // =========================================================================
    // Month key determinism: same timestamp always gives same month key
    // =========================================================================

    /// @dev Volume recorded in the same month always accumulates
    function testFuzz_sameMonthVolumeAccumulates(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, type(uint88).max));
        b = uint96(bound(b, 1, type(uint88).max));

        address p = makeAddr("p1");

        vm.startPrank(caller);
        fee.recordTransaction(p, a);
        fee.recordTransaction(p, b);
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(p), uint256(a) + uint256(b));
    }

    /// @dev Volume resets when crossing any month boundary
    function testFuzz_volumeResetsOnNewMonth(uint96 amount, uint32 dayOffset) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        dayOffset = uint32(bound(dayOffset, 28, 365)); // at least 28 days forward guarantees new month

        address p = makeAddr("p2");

        vm.prank(caller);
        fee.recordTransaction(p, amount);
        assertEq(fee.getMonthlyVolume(p), amount);

        // Warp forward by at least 28 days (guaranteed new month)
        vm.warp(block.timestamp + uint256(dayOffset) * 1 days);

        assertEq(fee.getMonthlyVolume(p), 0);
    }

    // =========================================================================
    // Fee monotonicity: higher amount => higher or equal fee
    // =========================================================================

    /// @dev Fee is monotonically non-decreasing with amount (same provider/volume)
    function testFuzz_feeMonotonicity(uint96 amountLow, uint96 amountHigh, uint96 volume) public {
        amountLow = uint96(bound(amountLow, 100, type(uint88).max));
        amountHigh = uint96(bound(amountHigh, amountLow, type(uint88).max));
        volume = uint96(bound(volume, 0, type(uint88).max));

        address p = makeAddr("p3");
        if (volume > 0) {
            vm.prank(caller);
            fee.recordTransaction(p, volume);
        }

        uint96 feeLow = fee.calculateFee(p, amountLow);
        uint96 feeHigh = fee.calculateFee(p, amountHigh);
        assertLe(feeLow, feeHigh, "fee must be monotonically non-decreasing with amount");
    }

    // =========================================================================
    // Preferred rate is always <= standard rate for same amount
    // =========================================================================

    /// @dev Once above threshold, fee is always <= what it would be at standard rate
    function testFuzz_preferredRateNeverExceedsStandard(uint96 amount) public {
        amount = uint96(bound(amount, 100, type(uint96).max));

        address p = makeAddr("p4");

        // Standard rate (no volume)
        uint96 standardFee = fee.calculateFee(p, amount);

        // Push above threshold
        vm.prank(caller);
        fee.recordTransaction(p, PayTypes.FEE_THRESHOLD);

        // Preferred rate
        uint96 preferredFee = fee.calculateFee(p, amount);

        assertLe(preferredFee, standardFee, "preferred fee must not exceed standard fee");
    }

    // =========================================================================
    // Fee precision: fee * 10000 / amount should equal the rate in bps
    // =========================================================================

    /// @dev Fee is exactly rate * amount / 10000 (no rounding beyond integer division)
    function testFuzz_feeExactCalculation(uint96 amount, uint96 volume) public {
        amount = uint96(bound(amount, 100, type(uint96).max));
        volume = uint96(bound(volume, 0, type(uint96).max - amount));

        address p = makeAddr("p5");
        if (volume > 0) {
            vm.prank(caller);
            fee.recordTransaction(p, volume);
        }

        uint96 f = fee.calculateFee(p, amount);
        uint96 rate =
            volume >= PayTypes.FEE_THRESHOLD ? PayTypes.FEE_RATE_PREFERRED_BPS : PayTypes.FEE_RATE_BPS;

        assertEq(f, uint96((uint256(amount) * rate) / 10_000));
    }

    // =========================================================================
    // Per-provider isolation under fuzz
    // =========================================================================

    /// @dev Two providers' volumes never interfere
    function testFuzz_providerIsolation(uint96 volumeA, uint96 volumeB) public {
        volumeA = uint96(bound(volumeA, 1, type(uint88).max));
        volumeB = uint96(bound(volumeB, 1, type(uint88).max));

        address pA = makeAddr("pA");
        address pB = makeAddr("pB");

        vm.startPrank(caller);
        fee.recordTransaction(pA, volumeA);
        fee.recordTransaction(pB, volumeB);
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(pA), volumeA);
        assertEq(fee.getMonthlyVolume(pB), volumeB);
    }
}

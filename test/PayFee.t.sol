// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";

/// @title PayFeeTest
/// @notice Unit tests for PayFee.sol
/// @dev Deploys the calculator behind a real ERC1967Proxy to test the UUPS pattern.
contract PayFeeTest is Test {
    PayFee internal fee;

    address internal owner = makeAddr("owner");
    address internal caller = makeAddr("caller"); // authorized contract
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    // Fee constants from PayTypes
    uint96 constant THRESHOLD = PayTypes.FEE_THRESHOLD; // $50,000
    uint96 constant STANDARD = PayTypes.FEE_RATE_BPS; // 100 bps = 1%
    uint96 constant PREFERRED = PayTypes.FEE_RATE_PREFERRED_BPS; // 75 bps = 0.75%

    function setUp() public {
        // Deploy via UUPS proxy (same as production).
        PayFee impl = new PayFee();
        bytes memory data = abi.encodeCall(impl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(impl), data)));

        // Authorize `caller` as a fund-holding contract.
        vm.prank(owner);
        fee.authorizeCaller(caller);

        // Warp to a known date: 2026-03-15 00:00:00 UTC
        vm.warp(1773532800);
    }

    // =========================================================================
    // initialize
    // =========================================================================

    function test_initialize_setsOwner() public view {
        assertEq(fee.owner(), owner);
    }

    function test_initialize_revertsIfCalledAgain() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, address(this)));
        fee.initialize(stranger);
    }

    function test_initialize_revertsOnZeroOwner() public {
        PayFee impl = new PayFee();
        bytes memory data = abi.encodeCall(impl.initialize, (address(0)));
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), data);
    }

    // =========================================================================
    // calculateFee — standard rate (below cliff)
    // =========================================================================

    function test_calculateFee_standardRate_zeroVolume() public view {
        uint96 amount = 1_000e6; // $1,000
        uint96 f = fee.calculateFee(provider, amount);
        assertEq(f, (uint256(amount) * STANDARD) / 10_000);
    }

    function test_calculateFee_standardRate_halfwayToThreshold() public {
        vm.prank(caller);
        fee.recordTransaction(provider, 25_000e6);

        uint96 amount = 500e6;
        uint96 f = fee.calculateFee(provider, amount);
        assertEq(f, (uint256(amount) * STANDARD) / 10_000);
    }

    function test_calculateFee_standardRate_exactlyAtThreshold() public {
        // Volume at $50,000 → preferred rate for any additional
        vm.prank(caller);
        fee.recordTransaction(provider, THRESHOLD);

        uint96 amount = 1_000e6;
        uint96 f = fee.calculateFee(provider, amount);
        assertEq(f, (uint256(amount) * PREFERRED) / 10_000);
    }

    // =========================================================================
    // calculateFee — preferred rate (above cliff)
    // =========================================================================

    function test_calculateFee_preferredRate_aboveThreshold() public {
        vm.prank(caller);
        fee.recordTransaction(provider, THRESHOLD + 1_000e6);

        uint96 amount = 2_000e6;
        uint96 f = fee.calculateFee(provider, amount);
        assertEq(f, (uint256(amount) * PREFERRED) / 10_000);
    }

    // =========================================================================
    // calculateFee — cliff behavior (no marginal split)
    // =========================================================================

    function test_calculateFee_cliff_transactionCrossingThreshold() public {
        // Volume at $49,500. Transaction of $1,000 would cross $50k.
        // Cliff: entire $1,000 charged at STANDARD (you haven't crossed yet).
        vm.prank(caller);
        fee.recordTransaction(provider, 49_500e6);

        uint96 amount = 1_000e6;
        uint96 f = fee.calculateFee(provider, amount);
        assertEq(f, (uint256(amount) * STANDARD) / 10_000);
    }

    function test_calculateFee_cliff_firstTransactionAfterCrossing() public {
        // Volume at $49,500 + record $1,000 → volume = $50,500 (above cliff).
        vm.startPrank(caller);
        fee.recordTransaction(provider, 49_500e6);
        fee.recordTransaction(provider, 1_000e6);
        vm.stopPrank();

        // Next transaction should be at preferred rate.
        uint96 amount = 500e6;
        uint96 f = fee.calculateFee(provider, amount);
        assertEq(f, (uint256(amount) * PREFERRED) / 10_000);
    }

    function test_calculateFee_cliff_oneBelowThreshold() public {
        vm.prank(caller);
        fee.recordTransaction(provider, THRESHOLD - 1);

        uint96 f = fee.calculateFee(provider, 1_000e6);
        assertEq(f, (uint256(1_000e6) * STANDARD) / 10_000);
    }

    // =========================================================================
    // calculateFee — reverts on zero amount and zero fee
    // =========================================================================

    function test_calculateFee_revertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAmount.selector));
        fee.calculateFee(provider, 0);
    }

    function test_calculateFee_revertsOnDustAmount() public {
        // Amount so small that fee rounds to 0: e.g., 99 units at 1% = 0
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroFee.selector, uint96(99)));
        fee.calculateFee(provider, 99);
    }

    // =========================================================================
    // calculateFee — does not write state (view function)
    // =========================================================================

    function test_calculateFee_doesNotChangeVolume() public {
        uint256 volBefore = fee.getMonthlyVolume(provider);
        fee.calculateFee(provider, 1_000e6);
        assertEq(fee.getMonthlyVolume(provider), volBefore);
    }

    // =========================================================================
    // getFeeRate
    // =========================================================================

    function test_getFeeRate_standard_zeroVolume() public view {
        assertEq(fee.getFeeRate(provider), STANDARD);
    }

    function test_getFeeRate_preferred_afterThreshold() public {
        vm.prank(caller);
        fee.recordTransaction(provider, THRESHOLD);
        assertEq(fee.getFeeRate(provider), PREFERRED);
    }

    // =========================================================================
    // recordTransaction
    // =========================================================================

    function test_recordTransaction_accumulatesVolume() public {
        vm.startPrank(caller);
        fee.recordTransaction(provider, 1_000e6);
        fee.recordTransaction(provider, 2_000e6);
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(provider), 3_000e6);
    }

    function test_recordTransaction_revertsIfUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        fee.recordTransaction(provider, 1_000e6);
    }

    // =========================================================================
    // Calendar month volume reset
    // =========================================================================

    function test_volumeResets_onCalendarMonthBoundary() public {
        // Record volume on March 15, 2026
        vm.prank(caller);
        fee.recordTransaction(provider, 40_000e6);
        assertEq(fee.getMonthlyVolume(provider), 40_000e6);

        // Warp to April 1, 2026 00:00:00 UTC (next calendar month)
        vm.warp(1775001600);

        // Volume is now 0 (new month).
        assertEq(fee.getMonthlyVolume(provider), 0);

        // Fee recalculates from zero → standard rate.
        uint96 f = fee.calculateFee(provider, 1_000e6);
        assertEq(f, (1_000e6 * STANDARD) / 10_000);
    }

    function test_recordTransaction_resetsThenAccumulates() public {
        // Record in March 2026
        vm.prank(caller);
        fee.recordTransaction(provider, 40_000e6);

        // Warp to April 1, 2026
        vm.warp(1775001600);

        // Record in new month — should start fresh.
        vm.prank(caller);
        fee.recordTransaction(provider, 500e6);

        assertEq(fee.getMonthlyVolume(provider), 500e6);
    }

    function test_volumeNotReset_sameMonth() public {
        // Record on March 1, 2026
        vm.warp(1772323200);
        vm.prank(caller);
        fee.recordTransaction(provider, 20_000e6);

        // Warp to March 31, 2026 23:59:59 UTC (same month)
        vm.warp(1775001599);

        vm.prank(caller);
        fee.recordTransaction(provider, 10_000e6);

        assertEq(fee.getMonthlyVolume(provider), 30_000e6);
    }

    function test_volumeResets_jan31ToFeb1() public {
        // Warp to Jan 31, 2026 12:00:00 UTC
        vm.warp(1769860800);

        vm.prank(caller);
        fee.recordTransaction(provider, 30_000e6);
        assertEq(fee.getMonthlyVolume(provider), 30_000e6);

        // Warp to Feb 1, 2026 00:00:00 UTC
        vm.warp(1769904000);

        assertEq(fee.getMonthlyVolume(provider), 0);
    }

    function test_volumeNotReset_sameDayDifferentHour() public {
        // Warp to March 15, 2026 08:00:00 UTC
        vm.warp(1773561600);

        vm.prank(caller);
        fee.recordTransaction(provider, 15_000e6);

        // Warp to March 15, 2026 20:00:00 UTC (same day)
        vm.warp(1773604800);

        vm.prank(caller);
        fee.recordTransaction(provider, 5_000e6);

        assertEq(fee.getMonthlyVolume(provider), 20_000e6);
    }

    // =========================================================================
    // Per-provider isolation
    // =========================================================================

    function test_volumeIsolated_perProvider() public {
        address providerA = makeAddr("providerA");
        address providerB = makeAddr("providerB");

        vm.startPrank(caller);
        fee.recordTransaction(providerA, THRESHOLD);
        fee.recordTransaction(providerB, 1_000e6);
        vm.stopPrank();

        // Provider A at preferred, provider B still at standard
        assertEq(fee.getFeeRate(providerA), PREFERRED);
        assertEq(fee.getFeeRate(providerB), STANDARD);
    }

    // =========================================================================
    // authorizeCaller / revokeCaller
    // =========================================================================

    function test_authorizeCaller_onlyOwner() public {
        address newCaller = makeAddr("new");
        vm.prank(owner);
        fee.authorizeCaller(newCaller);
        assertTrue(fee.authorizedCallers(newCaller));
    }

    function test_authorizeCaller_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        fee.authorizeCaller(makeAddr("x"));
    }

    function test_authorizeCaller_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(owner);
        fee.authorizeCaller(address(0));
    }

    function test_revokeCaller_works() public {
        vm.prank(owner);
        fee.revokeCaller(caller);
        assertFalse(fee.authorizedCallers(caller));

        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, caller));
        vm.prank(caller);
        fee.recordTransaction(provider, 100e6);
    }

    // =========================================================================
    // transferOwnership
    // =========================================================================

    function test_transferOwnership_works() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        fee.transferOwnership(newOwner);
        assertEq(fee.owner(), newOwner);
    }

    function test_transferOwnership_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        fee.transferOwnership(stranger);
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(owner);
        fee.transferOwnership(address(0));
    }

    // =========================================================================
    // Fuzz: fee invariants
    // =========================================================================

    /// @dev Fee is always <= amount (can never drain more than was sent).
    function testFuzz_fee_neverExceedsAmount(uint96 amount, uint96 volume) public {
        amount = uint96(bound(amount, 100, type(uint96).max));
        volume = uint96(bound(volume, 0, type(uint96).max - amount));

        if (volume > 0) {
            vm.prank(caller);
            fee.recordTransaction(provider, volume);
        }

        uint96 f = fee.calculateFee(provider, amount);
        assertLe(f, amount);
    }

    /// @dev getFeeRate returns either STANDARD or PREFERRED, nothing else.
    function testFuzz_getFeeRate_validValues(uint96 volume) public {
        if (volume > 0) {
            vm.prank(caller);
            fee.recordTransaction(provider, volume);
        }
        uint96 rate = fee.getFeeRate(provider);
        assertTrue(rate == STANDARD || rate == PREFERRED);
    }

    /// @dev Cliff fee: below threshold → always STANDARD rate, above → always PREFERRED.
    function testFuzz_calculateFee_cliffBehavior(uint96 txAmount, uint96 volume) public {
        txAmount = uint96(bound(txAmount, 100, type(uint96).max));
        volume = uint96(bound(volume, 0, type(uint96).max - txAmount));

        if (volume > 0) {
            vm.prank(caller);
            fee.recordTransaction(provider, volume);
        }

        uint96 f = fee.calculateFee(provider, txAmount);

        if (volume >= THRESHOLD) {
            assertEq(f, uint96((uint256(txAmount) * PREFERRED) / 10_000));
        } else {
            assertEq(f, uint96((uint256(txAmount) * STANDARD) / 10_000));
        }
    }
}

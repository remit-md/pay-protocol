// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayRouter} from "../src/PayRouter.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDCRouter
/// @notice Minimal ERC-20 + EIP-3009 mock for testing PayRouter.
///         receiveWithAuthorization simulates USDC's behavior: enforces to == msg.sender,
///         transfers value from `from` to `to`. Signature validation is skipped (mock).
contract MockUSDCRouter {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes32 => bool) public authorizationUsed;

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

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256, /* validAfter */
        uint256, /* validBefore */
        bytes32 nonce,
        uint8, /* v */
        bytes32, /* r */
        bytes32 /* s */
    ) external {
        require(to == msg.sender, "EIP3009: to != caller");
        require(!authorizationUsed[nonce], "EIP3009: nonce already used");
        require(balanceOf[from] >= value, "EIP3009: insufficient balance");
        authorizationUsed[nonce] = true;
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }

    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external pure {}
}

/// @title PayRouterTest
/// @notice Unit tests for PayRouter.sol
contract PayRouterTest is Test {
    PayRouter internal router;
    PayFee internal fee;
    MockUSDCRouter internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    uint96 constant MIN = PayTypes.MIN_DIRECT_AMOUNT; // $1.00
    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS; // 100
    uint96 constant PREFERRED_BPS = PayTypes.FEE_RATE_PREFERRED_BPS; // 75
    uint96 constant THRESHOLD = PayTypes.FEE_THRESHOLD; // $50k

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDCRouter();

        // Deploy PayFee behind UUPS proxy
        PayFee feeImpl = new PayFee();
        bytes memory feeData = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), feeData)));

        // Deploy PayRouter behind UUPS proxy
        PayRouter routerImpl = new PayRouter();
        bytes memory routerData = abi.encodeCall(routerImpl.initialize, (owner, address(usdc), address(fee), feeWallet));
        router = PayRouter(address(new ERC1967Proxy(address(routerImpl), routerData)));

        // Authorize PayRouter to record transactions on PayFee
        vm.prank(owner);
        fee.authorizeCaller(address(router));

        // Authorize relayer on PayRouter
        vm.prank(owner);
        router.authorizeRelayer(relayer);

        // Fund agent with USDC
        usdc.mint(agent, 1_000_000e6); // $1M

        // Warp to a known date: 2026-03-15 00:00:00 UTC
        vm.warp(1773532800);
    }

    // =========================================================================
    // Initialize
    // =========================================================================

    function test_initialize_setsState() public view {
        assertEq(address(router.usdc()), address(usdc));
        assertEq(address(router.payFee()), address(fee));
        assertEq(router.feeWallet(), feeWallet);
        assertEq(router.owner(), owner);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, address(this)));
        router.initialize(owner, address(usdc), address(fee), feeWallet);
    }

    function test_initialize_revertsOnZeroOwner() public {
        PayRouter impl = new PayRouter();
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(impl.initialize, (address(0), address(usdc), address(fee), feeWallet))
        );
    }

    function test_initialize_revertsOnZeroUsdc() public {
        PayRouter impl = new PayRouter();
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), abi.encodeCall(impl.initialize, (owner, address(0), address(fee), feeWallet)));
    }

    function test_initialize_revertsOnZeroFee() public {
        PayRouter impl = new PayRouter();
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), abi.encodeCall(impl.initialize, (owner, address(usdc), address(0), feeWallet)));
    }

    function test_initialize_revertsOnZeroFeeWallet() public {
        PayRouter impl = new PayRouter();
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(impl.initialize, (owner, address(usdc), address(fee), address(0)))
        );
    }

    // =========================================================================
    // Relayer management
    // =========================================================================

    function test_authorizeRelayer_works() public {
        address newRelayer = makeAddr("newRelayer");
        assertFalse(router.isAuthorizedRelayer(newRelayer));

        vm.prank(owner);
        router.authorizeRelayer(newRelayer);

        assertTrue(router.isAuthorizedRelayer(newRelayer));
    }

    function test_authorizeRelayer_emitsEvent() public {
        address newRelayer = makeAddr("newRelayer");

        vm.expectEmit(true, false, false, false);
        emit PayEvents.CallerAuthorized(newRelayer);

        vm.prank(owner);
        router.authorizeRelayer(newRelayer);
    }

    function test_authorizeRelayer_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.authorizeRelayer(makeAddr("x"));
    }

    function test_authorizeRelayer_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(owner);
        router.authorizeRelayer(address(0));
    }

    function test_revokeRelayer_works() public {
        assertTrue(router.isAuthorizedRelayer(relayer));

        vm.prank(owner);
        router.revokeRelayer(relayer);

        assertFalse(router.isAuthorizedRelayer(relayer));
    }

    function test_revokeRelayer_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit PayEvents.CallerRevoked(relayer);

        vm.prank(owner);
        router.revokeRelayer(relayer);
    }

    function test_revokeRelayer_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.revokeRelayer(relayer);
    }

    function test_revokeRelayer_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(owner);
        router.revokeRelayer(address(0));
    }

    // =========================================================================
    // settleX402 — happy path
    // =========================================================================

    function test_settleX402_transfersCorrectAmounts() public {
        uint96 amount = 100e6; // $100
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000); // $1
        uint96 expectedProvider = amount - expectedFee; // $99

        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("nonce1"), 0, bytes32(0), bytes32(0));

        assertEq(usdc.balanceOf(provider), expectedProvider);
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
        assertEq(usdc.balanceOf(agent), agentBefore - amount);
        // Router should hold no USDC
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_settleX402_emitsEvent() public {
        uint96 amount = 50e6;
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000);
        bytes32 nonce = bytes32("nonce-emit");

        vm.expectEmit(true, true, true, true);
        emit PayEvents.X402Settled(agent, provider, amount, expectedFee, nonce);

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, nonce, 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_recordsVolume() public {
        uint96 amount = 10e6;

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("vol"), 0, bytes32(0), bytes32(0));

        assertEq(fee.getMonthlyVolume(provider), amount);
    }

    function test_settleX402_minimumAmount() public {
        uint96 amount = MIN; // exactly $1.00
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000);

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("min"), 0, bytes32(0), bytes32(0));

        assertEq(usdc.balanceOf(provider), amount - expectedFee);
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
    }

    function test_settleX402_largeAmount() public {
        uint96 amount = 500_000e6; // $500k
        usdc.mint(agent, amount); // extra funds

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("large"), 0, bytes32(0), bytes32(0));

        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000);
        assertEq(usdc.balanceOf(provider), amount - expectedFee);
    }

    function test_settleX402_routerHoldsNoFunds() public {
        vm.prank(relayer);
        router.settleX402(agent, provider, 10e6, 0, type(uint256).max, bytes32("no-hold"), 0, bytes32(0), bytes32(0));

        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // =========================================================================
    // settleX402 — preferred rate after volume threshold
    // =========================================================================

    function test_settleX402_preferredRate_afterThreshold() public {
        // Push provider past $50k volume
        vm.prank(relayer);
        router.settleX402(agent, provider, 50_000e6, 0, type(uint256).max, bytes32("push"), 0, bytes32(0), bytes32(0));

        // Next settlement should use preferred rate
        uint96 amount = 1_000e6;
        uint96 expectedFee = uint96((uint256(amount) * PREFERRED_BPS) / 10_000);

        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("pref"), 0, bytes32(0), bytes32(0));

        assertEq(usdc.balanceOf(provider) - providerBefore, amount - expectedFee);
    }

    // =========================================================================
    // settleX402 — reverts
    // =========================================================================

    function test_settleX402_revertsForNonRelayer() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.settleX402(agent, provider, 5e6, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnZeroFrom() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(relayer);
        router.settleX402(address(0), provider, 5e6, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnZeroTo() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(relayer);
        router.settleX402(agent, address(0), 5e6, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnSelfPayment() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.SelfPayment.selector, agent));
        vm.prank(relayer);
        router.settleX402(agent, agent, 5e6, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, uint96(999_999), MIN));
        vm.prank(relayer);
        router.settleX402(agent, provider, 999_999, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, uint96(0), MIN));
        vm.prank(relayer);
        router.settleX402(agent, provider, 0, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnInsufficientBalance() public {
        address broke = makeAddr("broke");
        // broke has no USDC — receiveWithAuthorization will revert
        vm.expectRevert("EIP3009: insufficient balance");
        vm.prank(relayer);
        router.settleX402(broke, provider, 5e6, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsOnNonceReplay() public {
        bytes32 nonce = bytes32("once");

        vm.prank(relayer);
        router.settleX402(agent, provider, 5e6, 0, type(uint256).max, nonce, 0, bytes32(0), bytes32(0));

        // Same nonce again should revert
        vm.expectRevert("EIP3009: nonce already used");
        vm.prank(relayer);
        router.settleX402(agent, provider, 5e6, 0, type(uint256).max, nonce, 0, bytes32(0), bytes32(0));
    }

    function test_settleX402_revertsAfterRelayerRevoked() public {
        vm.prank(owner);
        router.revokeRelayer(relayer);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, relayer));
        vm.prank(relayer);
        router.settleX402(agent, provider, 5e6, 0, type(uint256).max, bytes32("x"), 0, bytes32(0), bytes32(0));
    }

    // =========================================================================
    // Volume accumulation across settlements
    // =========================================================================

    function test_volumeAccumulates_acrossSettlements() public {
        vm.startPrank(relayer);
        router.settleX402(agent, provider, 10e6, 0, type(uint256).max, bytes32("v1"), 0, bytes32(0), bytes32(0));
        router.settleX402(agent, provider, 20e6, 0, type(uint256).max, bytes32("v2"), 0, bytes32(0), bytes32(0));
        router.settleX402(agent, provider, 30e6, 0, type(uint256).max, bytes32("v3"), 0, bytes32(0), bytes32(0));
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(provider), 60e6);
    }

    function test_volumeIsolated_perProvider() public {
        address providerB = makeAddr("providerB");

        vm.startPrank(relayer);
        router.settleX402(agent, provider, 10e6, 0, type(uint256).max, bytes32("pa"), 0, bytes32(0), bytes32(0));
        router.settleX402(agent, providerB, 20e6, 0, type(uint256).max, bytes32("pb"), 0, bytes32(0), bytes32(0));
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(provider), 10e6);
        assertEq(fee.getMonthlyVolume(providerB), 20e6);
    }

    // =========================================================================
    // Fee accounting — no dust
    // =========================================================================

    function test_feeAccounting_noLostDust() public {
        uint96 amount = 100e6;
        uint256 totalBefore = usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet);

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("dust"), 0, bytes32(0), bytes32(0));

        uint256 totalAfter = usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet);
        assertEq(totalAfter, totalBefore);
    }

    function test_feeAccounting_providerPlusFeeEqualsAmount() public {
        uint96 amount = 77_777_777; // ~$77.78 — non-round number

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("acc"), 0, bytes32(0), bytes32(0));

        uint256 providerGot = usdc.balanceOf(provider);
        uint256 feeGot = usdc.balanceOf(feeWallet);
        assertEq(providerGot + feeGot, amount);
    }

    // =========================================================================
    // Multiple agents, same provider
    // =========================================================================

    function test_multipleAgents_sameProvider() public {
        address agent2 = makeAddr("agent2");
        usdc.mint(agent2, 100e6);

        vm.startPrank(relayer);
        router.settleX402(agent, provider, 10e6, 0, type(uint256).max, bytes32("a1"), 0, bytes32(0), bytes32(0));
        router.settleX402(agent2, provider, 10e6, 0, type(uint256).max, bytes32("a2"), 0, bytes32(0), bytes32(0));
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(provider), 20e6);
    }

    // =========================================================================
    // Ownership
    // =========================================================================

    function test_transferOwnership_works() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        router.transferOwnership(newOwner);

        assertEq(router.owner(), newOwner);
    }

    function test_transferOwnership_emitsEvent() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, false, false);
        emit PayEvents.OwnershipTransferred(owner, newOwner);

        vm.prank(owner);
        router.transferOwnership(newOwner);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.transferOwnership(stranger);
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(owner);
        router.transferOwnership(address(0));
    }

    // =========================================================================
    // Multiple relayers
    // =========================================================================

    function test_multipleRelayers_canSettle() public {
        address relayer2 = makeAddr("relayer2");

        vm.prank(owner);
        router.authorizeRelayer(relayer2);

        // Both relayers can settle
        vm.prank(relayer);
        router.settleX402(agent, provider, 5e6, 0, type(uint256).max, bytes32("r1"), 0, bytes32(0), bytes32(0));

        vm.prank(relayer2);
        router.settleX402(agent, provider, 5e6, 0, type(uint256).max, bytes32("r2"), 0, bytes32(0), bytes32(0));

        assertEq(fee.getMonthlyVolume(provider), 10e6);
    }
}

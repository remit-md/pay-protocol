// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayDirect} from "../src/PayDirect.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDC
/// @notice Minimal ERC-20 mock for testing. Tracks balances and allowances.
contract MockUSDC {
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

/// @title PayDirectTest
/// @notice Unit tests for PayDirect.sol
contract PayDirectTest is Test {
    PayDirect internal direct;
    PayFee internal fee;
    MockUSDC internal usdc;

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
        usdc = new MockUSDC();

        // Deploy PayFee behind UUPS proxy
        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        // Deploy PayDirect (immutable)
        direct = new PayDirect(address(usdc), address(fee), feeWallet, relayer);

        // Authorize PayDirect to record transactions on PayFee
        vm.prank(owner);
        fee.authorizeCaller(address(direct));

        // Fund agent with USDC and approve PayDirect
        usdc.mint(agent, 1_000_000e6); // $1M
        vm.prank(agent);
        usdc.approve(address(direct), type(uint256).max);

        // Warp to a known date: 2026-03-15 00:00:00 UTC
        vm.warp(1773532800);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(address(direct.usdc()), address(usdc));
        assertEq(address(direct.payFee()), address(fee));
        assertEq(direct.feeWallet(), feeWallet);
        assertEq(direct.relayer(), relayer);
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new PayDirect(address(0), address(fee), feeWallet, relayer);
    }

    function test_constructor_revertsOnZeroFee() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new PayDirect(address(usdc), address(0), feeWallet, relayer);
    }

    function test_constructor_revertsOnZeroFeeWallet() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new PayDirect(address(usdc), address(fee), address(0), relayer);
    }

    function test_constructor_revertsOnZeroRelayer() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new PayDirect(address(usdc), address(fee), feeWallet, address(0));
    }

    // =========================================================================
    // payDirect — happy path
    // =========================================================================

    function test_payDirect_transfersCorrectAmounts() public {
        uint96 amount = 100e6; // $100
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000); // $1
        uint96 expectedProvider = amount - expectedFee; // $99

        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32("task-42"));

        assertEq(usdc.balanceOf(provider), expectedProvider);
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
        assertEq(usdc.balanceOf(agent), agentBefore - amount);
    }

    function test_payDirect_emitsEvent() public {
        uint96 amount = 50e6;
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000);
        bytes32 memo = bytes32("memo-1");

        vm.expectEmit(true, true, false, true);
        emit PayEvents.DirectPayment(agent, provider, amount, expectedFee, memo);

        vm.prank(agent);
        direct.payDirect(provider, amount, memo);
    }

    function test_payDirect_recordsVolume() public {
        uint96 amount = 10e6;

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        assertEq(fee.getMonthlyVolume(provider), amount);
    }

    function test_payDirect_minimumAmount() public {
        uint96 amount = MIN; // exactly $1.00
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000); // $0.01

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        assertEq(usdc.balanceOf(provider), amount - expectedFee);
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
    }

    function test_payDirect_largeAmount() public {
        uint96 amount = 500_000e6; // $500k
        usdc.mint(agent, amount); // extra funds

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000);
        assertEq(usdc.balanceOf(provider), amount - expectedFee);
    }

    function test_payDirect_emptyMemo() public {
        vm.prank(agent);
        direct.payDirect(provider, 5e6, bytes32(0));

        assertGt(usdc.balanceOf(provider), 0);
    }

    // =========================================================================
    // payDirect — preferred rate after volume threshold
    // =========================================================================

    function test_payDirect_preferredRate_afterThreshold() public {
        // Push provider past $50k volume
        vm.startPrank(agent);
        direct.payDirect(provider, 50_000e6, bytes32(0));

        // Next payment should use preferred rate
        uint96 amount = 1_000e6;
        uint96 expectedFee = uint96((uint256(amount) * PREFERRED_BPS) / 10_000);

        uint256 providerBefore = usdc.balanceOf(provider);
        direct.payDirect(provider, amount, bytes32(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(provider) - providerBefore, amount - expectedFee);
    }

    // =========================================================================
    // payDirect — reverts
    // =========================================================================

    function test_payDirect_revertsOnZeroTo() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(agent);
        direct.payDirect(address(0), 5e6, bytes32(0));
    }

    function test_payDirect_revertsOnSelfPayment() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.SelfPayment.selector, agent));
        vm.prank(agent);
        direct.payDirect(agent, 5e6, bytes32(0));
    }

    function test_payDirect_revertsOnBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, uint96(999_999), MIN));
        vm.prank(agent);
        direct.payDirect(provider, 999_999, bytes32(0));
    }

    function test_payDirect_revertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, uint96(0), MIN));
        vm.prank(agent);
        direct.payDirect(provider, 0, bytes32(0));
    }

    function test_payDirect_revertsOnInsufficientBalance() public {
        address broke = makeAddr("broke");
        vm.prank(broke);
        usdc.approve(address(direct), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TransferFailed.selector));
        vm.prank(broke);
        direct.payDirect(provider, 5e6, bytes32(0));
    }

    function test_payDirect_revertsOnInsufficientAllowance() public {
        address noApproval = makeAddr("noApproval");
        usdc.mint(noApproval, 100e6);
        // No approve call

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TransferFailed.selector));
        vm.prank(noApproval);
        direct.payDirect(provider, 5e6, bytes32(0));
    }

    // =========================================================================
    // payDirectFor — happy path
    // =========================================================================

    function test_payDirectFor_transfersCorrectAmounts() public {
        uint96 amount = 200e6;
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000);
        uint96 expectedProvider = amount - expectedFee;

        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(relayer);
        direct.payDirectFor(agent, provider, amount, bytes32("relayed"));

        assertEq(usdc.balanceOf(provider), expectedProvider);
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
        assertEq(usdc.balanceOf(agent), agentBefore - amount);
    }

    function test_payDirectFor_emitsEvent() public {
        uint96 amount = 25e6;
        uint96 expectedFee = uint96((uint256(amount) * STANDARD_BPS) / 10_000);
        bytes32 memo = bytes32("relayed-memo");

        vm.expectEmit(true, true, false, true);
        emit PayEvents.DirectPayment(agent, provider, amount, expectedFee, memo);

        vm.prank(relayer);
        direct.payDirectFor(agent, provider, amount, memo);
    }

    function test_payDirectFor_recordsVolume() public {
        vm.prank(relayer);
        direct.payDirectFor(agent, provider, 30e6, bytes32(0));

        assertEq(fee.getMonthlyVolume(provider), 30e6);
    }

    // =========================================================================
    // payDirectFor — reverts
    // =========================================================================

    function test_payDirectFor_revertsForNonRelayer() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        direct.payDirectFor(agent, provider, 5e6, bytes32(0));
    }

    function test_payDirectFor_revertsForAgentCalling() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, agent));
        vm.prank(agent);
        direct.payDirectFor(agent, provider, 5e6, bytes32(0));
    }

    function test_payDirectFor_revertsOnZeroAgent() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(relayer);
        direct.payDirectFor(address(0), provider, 5e6, bytes32(0));
    }

    function test_payDirectFor_revertsOnZeroTo() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(relayer);
        direct.payDirectFor(agent, address(0), 5e6, bytes32(0));
    }

    function test_payDirectFor_revertsOnSelfPayment() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.SelfPayment.selector, agent));
        vm.prank(relayer);
        direct.payDirectFor(agent, agent, 5e6, bytes32(0));
    }

    function test_payDirectFor_revertsOnBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, uint96(500_000), MIN));
        vm.prank(relayer);
        direct.payDirectFor(agent, provider, 500_000, bytes32(0));
    }

    // =========================================================================
    // Volume accumulation across multiple payments
    // =========================================================================

    function test_volumeAccumulates_acrossPayments() public {
        vm.startPrank(agent);
        direct.payDirect(provider, 10e6, bytes32(0));
        direct.payDirect(provider, 20e6, bytes32(0));
        direct.payDirect(provider, 30e6, bytes32(0));
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(provider), 60e6);
    }

    function test_volumeIsolated_perProvider() public {
        address providerB = makeAddr("providerB");

        vm.startPrank(agent);
        direct.payDirect(provider, 10e6, bytes32(0));
        direct.payDirect(providerB, 20e6, bytes32(0));
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

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        uint256 totalAfter = usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet);

        // Total USDC in the system is conserved (no dust created or destroyed).
        assertEq(totalAfter, totalBefore);
    }

    function test_feeAccounting_providerPlusFeeEqualsAmount() public {
        uint96 amount = 77_777_777; // ~$77.78 — non-round number

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        uint256 providerGot = usdc.balanceOf(provider);
        uint256 feeGot = usdc.balanceOf(feeWallet);

        assertEq(providerGot + feeGot, amount);
    }

    // =========================================================================
    // Multiple agents to same provider
    // =========================================================================

    function test_multipleAgents_sameProvider() public {
        address agent2 = makeAddr("agent2");
        usdc.mint(agent2, 100e6);
        vm.prank(agent2);
        usdc.approve(address(direct), type(uint256).max);

        vm.prank(agent);
        direct.payDirect(provider, 10e6, bytes32("a1"));

        vm.prank(agent2);
        direct.payDirect(provider, 10e6, bytes32("a2"));

        // Volume should accumulate from both agents
        assertEq(fee.getMonthlyVolume(provider), 20e6);
    }
}

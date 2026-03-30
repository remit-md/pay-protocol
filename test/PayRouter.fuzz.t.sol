// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayRouter} from "../src/PayRouter.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";

/// @title MockUSDCRouterFuzz
/// @notice Minimal ERC-20 + EIP-3009 mock for fuzz testing PayRouter.
contract MockUSDCRouterFuzz {
    mapping(address => uint256) public balanceOf;
    mapping(bytes32 => bool) public authorizationUsed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32 nonce,
        uint8,
        bytes32,
        bytes32
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

/// @title PayRouterFuzzTest
/// @notice Fuzz tests for PayRouter numeric operations
contract PayRouterFuzzTest is Test {
    PayRouter internal router;
    PayFee internal fee;
    MockUSDCRouterFuzz internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");

    function setUp() public {
        usdc = new MockUSDCRouterFuzz();

        PayFee feeImpl = new PayFee();
        bytes memory feeData = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), feeData)));

        PayRouter routerImpl = new PayRouter();
        bytes memory routerData = abi.encodeCall(routerImpl.initialize, (owner, address(usdc), address(fee), feeWallet));
        router = PayRouter(address(new ERC1967Proxy(address(routerImpl), routerData)));

        vm.prank(owner);
        fee.authorizeCaller(address(router));

        vm.prank(owner);
        router.authorizeRelayer(relayer);

        // Warp to 2026-03-15
        vm.warp(1773532800);
    }

    /// @notice Provider + fee always equals the original amount (no dust).
    function testFuzz_settleX402_noLostDust(uint96 amount, address agent, address provider) public {
        // Bound to valid range: >= $1, reasonable max, valid addresses
        amount = uint96(bound(amount, PayTypes.MIN_DIRECT_AMOUNT, 1_000_000_000e6));
        vm.assume(agent != address(0) && provider != address(0));
        vm.assume(agent != provider);
        vm.assume(provider != address(router) && provider != feeWallet);
        vm.assume(agent != address(router) && agent != feeWallet);

        usdc.mint(agent, amount);

        bytes32 nonce = keccak256(abi.encode(amount, agent, provider));

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, nonce, 0, bytes32(0), bytes32(0));

        uint256 providerGot = usdc.balanceOf(provider);
        uint256 feeGot = usdc.balanceOf(feeWallet);

        assertEq(providerGot + feeGot, amount, "provider + fee must equal amount");
        assertEq(usdc.balanceOf(address(router)), 0, "router must hold no funds");
    }

    /// @notice Fee is always strictly positive for valid amounts.
    function testFuzz_settleX402_feeAlwaysPositive(uint96 amount) public {
        amount = uint96(bound(amount, PayTypes.MIN_DIRECT_AMOUNT, 1_000_000_000e6));

        address agent = makeAddr("fuzzAgent");
        address provider = makeAddr("fuzzProvider");
        usdc.mint(agent, amount);

        bytes32 nonce = keccak256(abi.encode(amount, "positive"));

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, nonce, 0, bytes32(0), bytes32(0));

        assertGt(usdc.balanceOf(feeWallet), 0, "fee must be > 0");
    }

    /// @notice Provider always receives strictly less than the full amount (fee deducted).
    function testFuzz_settleX402_providerReceivesLessThanAmount(uint96 amount) public {
        amount = uint96(bound(amount, PayTypes.MIN_DIRECT_AMOUNT, 1_000_000_000e6));

        address agent = makeAddr("fuzzAgent2");
        address provider = makeAddr("fuzzProvider2");
        usdc.mint(agent, amount);

        bytes32 nonce = keccak256(abi.encode(amount, "less"));

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, nonce, 0, bytes32(0), bytes32(0));

        assertLt(usdc.balanceOf(provider), amount, "provider must receive less than full amount");
    }

    /// @notice Fee rate is bounded: never more than 1% at standard, never more than 0.75% at preferred.
    function testFuzz_settleX402_feeBounded(uint96 amount) public {
        amount = uint96(bound(amount, PayTypes.MIN_DIRECT_AMOUNT, 1_000_000_000e6));

        address agent = makeAddr("fuzzAgent3");
        address provider = makeAddr("fuzzProvider3");
        usdc.mint(agent, amount);

        bytes32 nonce = keccak256(abi.encode(amount, "bounded"));

        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, nonce, 0, bytes32(0), bytes32(0));

        uint256 feeGot = usdc.balanceOf(feeWallet);
        uint256 maxFee = (uint256(amount) * PayTypes.FEE_RATE_BPS) / 10_000;

        assertLe(feeGot, maxFee, "fee must not exceed 1%");
    }

    /// @notice Below-minimum amounts always revert.
    function testFuzz_settleX402_revertsOnBelowMinimum(uint96 amount) public {
        amount = uint96(bound(amount, 0, PayTypes.MIN_DIRECT_AMOUNT - 1));

        address agent = makeAddr("fuzzAgentMin");
        address provider = makeAddr("fuzzProviderMin");

        vm.expectRevert();
        vm.prank(relayer);
        router.settleX402(agent, provider, amount, 0, type(uint256).max, bytes32("min"), 0, bytes32(0), bytes32(0));
    }

    /// @notice Volume accumulates correctly across multiple fuzzed settlements.
    function testFuzz_settleX402_volumeAccumulates(uint96 amount1, uint96 amount2) public {
        amount1 = uint96(bound(amount1, PayTypes.MIN_DIRECT_AMOUNT, 100_000e6));
        amount2 = uint96(bound(amount2, PayTypes.MIN_DIRECT_AMOUNT, 100_000e6));

        address agent = makeAddr("fuzzAgentVol");
        address provider = makeAddr("fuzzProviderVol");
        usdc.mint(agent, uint256(amount1) + uint256(amount2));

        vm.startPrank(relayer);
        router.settleX402(agent, provider, amount1, 0, type(uint256).max, bytes32("fv1"), 0, bytes32(0), bytes32(0));
        router.settleX402(agent, provider, amount2, 0, type(uint256).max, bytes32("fv2"), 0, bytes32(0), bytes32(0));
        vm.stopPrank();

        assertEq(
            fee.getMonthlyVolume(provider), uint256(amount1) + uint256(amount2), "volume must equal sum of settlements"
        );
    }
}

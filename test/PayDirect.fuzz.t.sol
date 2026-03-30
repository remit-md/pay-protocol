// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayDirect} from "../src/PayDirect.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCFuzz
/// @notice Minimal ERC-20 mock for fuzz testing.
contract MockUSDCFuzz {
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

/// @title PayDirectFuzzTest
/// @notice Property-based fuzz tests for PayDirect.sol
contract PayDirectFuzzTest is Test {
    PayDirect internal direct;
    PayFee internal fee;
    MockUSDCFuzz internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    uint96 constant MIN = PayTypes.MIN_DIRECT_AMOUNT;
    uint96 constant STANDARD_BPS = PayTypes.FEE_RATE_BPS;
    uint96 constant PREFERRED_BPS = PayTypes.FEE_RATE_PREFERRED_BPS;
    uint96 constant THRESHOLD = PayTypes.FEE_THRESHOLD;

    function setUp() public {
        usdc = new MockUSDCFuzz();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        direct = new PayDirect(address(usdc), address(fee), feeWallet, relayer);

        vm.prank(owner);
        fee.authorizeCaller(address(direct));

        vm.warp(1773532800);
    }

    // =========================================================================
    // Property: USDC is conserved (no dust created or destroyed)
    // =========================================================================

    /// @dev For any valid payment amount, agent_loss == provider_gain + fee_gain.
    function testFuzz_usdcConserved(uint96 amount) public {
        // Min amount that produces non-zero fee: $1.00
        amount = uint96(bound(amount, MIN, type(uint96).max));

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(direct), amount);

        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        uint256 agentLoss = agentBefore - usdc.balanceOf(agent);
        uint256 providerGain = usdc.balanceOf(provider);
        uint256 feeGain = usdc.balanceOf(feeWallet);

        assertEq(agentLoss, providerGain + feeGain, "USDC not conserved");
        assertEq(agentLoss, amount, "agent should lose exactly the payment amount");
    }

    // =========================================================================
    // Property: fee never exceeds amount
    // =========================================================================

    /// @dev The fee deducted is always strictly less than the payment amount.
    function testFuzz_feeLessThanAmount(uint96 amount) public {
        amount = uint96(bound(amount, MIN, type(uint96).max));

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(direct), amount);

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        uint256 feeGot = usdc.balanceOf(feeWallet);
        assertLt(feeGot, amount, "fee must be less than amount");
    }

    // =========================================================================
    // Property: provider always receives majority
    // =========================================================================

    /// @dev Provider receives >= 99% of the payment (at standard rate), >= 99.25% at preferred.
    function testFuzz_providerReceivesMajority(uint96 amount) public {
        amount = uint96(bound(amount, MIN, type(uint96).max));

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(direct), amount);

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        uint256 providerGot = usdc.balanceOf(provider);
        // At worst (standard rate), provider gets amount * 99 / 100.
        // Due to integer truncation, provider might get 1 unit more than exact 99%.
        // But provider always gets >= amount * 99 / 100.
        assertGe(providerGot, uint256(amount) * 99 / 100, "provider must get >= 99%");
    }

    // =========================================================================
    // Property: fee matches PayFee calculation exactly
    // =========================================================================

    /// @dev The fee deducted equals PayFee.calculateFee for the same inputs.
    function testFuzz_feeMatchesCalculation(uint96 amount, uint96 priorVolume) public {
        amount = uint96(bound(amount, MIN, type(uint96).max));
        priorVolume = uint96(bound(priorVolume, 0, type(uint96).max));

        // Set up prior volume
        if (priorVolume > 0) {
            vm.prank(owner);
            fee.authorizeCaller(address(this));
            fee.recordTransaction(provider, priorVolume);
        }

        uint96 expectedFee = fee.calculateFee(provider, amount);

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(direct), amount);

        vm.prank(agent);
        direct.payDirect(provider, amount, bytes32(0));

        assertEq(usdc.balanceOf(feeWallet), expectedFee, "fee must match PayFee.calculateFee");
    }

    // =========================================================================
    // Property: volume accumulates correctly
    // =========================================================================

    /// @dev After N payments of amount A, volume equals N * A.
    function testFuzz_volumeAccumulates(uint96 amount, uint8 count) public {
        amount = uint96(bound(amount, MIN, 10_000e6)); // cap to avoid overflow
        count = uint8(bound(count, 1, 10)); // reasonable number of payments

        uint256 total = uint256(amount) * count;
        usdc.mint(agent, total);
        vm.prank(agent);
        usdc.approve(address(direct), total);

        vm.startPrank(agent);
        for (uint8 i = 0; i < count; i++) {
            direct.payDirect(provider, amount, bytes32(0));
        }
        vm.stopPrank();

        assertEq(fee.getMonthlyVolume(provider), total, "volume should equal sum of payments");
    }

    // =========================================================================
    // Property: payDirect and payDirectFor produce identical outcomes
    // =========================================================================

    /// @dev For the same inputs, both functions should result in identical balances.
    function testFuzz_directAndForIdentical(uint96 amount) public {
        amount = uint96(bound(amount, MIN, type(uint96).max / 2));

        address provider1 = makeAddr("p1");
        address provider2 = makeAddr("p2");

        // payDirect
        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(direct), amount);
        vm.prank(agent);
        direct.payDirect(provider1, amount, bytes32("direct"));

        // payDirectFor
        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(direct), amount);
        vm.prank(relayer);
        direct.payDirectFor(agent, provider2, amount, bytes32("for"));

        assertEq(usdc.balanceOf(provider1), usdc.balanceOf(provider2), "both paths should give same provider amount");
    }
}

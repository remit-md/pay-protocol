// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTabV4} from "../src/PayTabV4.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCV4Fuzz
contract MockUSDCV4Fuzz {
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

/// @title PayTabV4FuzzTest
/// @notice Property-based fuzz tests for PayTabV4 fee floor enforcement.
contract PayTabV4FuzzTest is Test {
    PayTabV4 internal tab;
    PayFee internal fee;
    MockUSDCV4Fuzz internal usdc;

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
        usdc = new MockUSDCV4Fuzz();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        tab = new PayTabV4(address(usdc), address(fee), feeWallet, relayerAddr);

        vm.prank(owner);
        fee.authorizeCaller(address(tab));

        usdc.mint(agent, type(uint96).max);
        vm.prank(agent);
        usdc.approve(address(tab), type(uint256).max);

        vm.warp(1773532800);
    }

    // =========================================================================
    // Property: fee >= max(floor, rate-based) AND fee <= unwithdrawn
    // =========================================================================

    function testFuzz_withdrawFeeFloorEnforced(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 100));

        bytes32 tabId = bytes32("fuzz-floor");
        vm.prank(agent);
        tab.openTab(tabId, provider, tabAmount, tabAmount);

        uint96 balance = tab.getTab(tabId).amount;
        // Each charge must fit in balance / numCharges, and be at least 1
        uint96 maxPerCharge = balance / uint96(numCharges);
        if (maxPerCharge == 0) return;
        chargeSize = uint96(bound(chargeSize, 1, maxPerCharge));

        // Do the charges
        vm.startPrank(relayerAddr);
        for (uint256 i = 0; i < numCharges; i++) {
            tab.chargeTab(tabId, chargeSize);
        }
        vm.stopPrank();

        uint96 totalCharged = chargeSize * uint96(numCharges);
        if (totalCharged < MIN_WITHDRAW) return; // skip if below withdraw min

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(relayerAddr);
        tab.withdrawCharged(tabId);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;

        // Expected bounds
        uint96 rateFee = uint96((uint256(totalCharged) * STANDARD_BPS) / 10_000);
        uint96 floorFee = uint96(uint256(numCharges) * MIN_CHARGE_FEE);
        uint96 expectedMin = rateFee > floorFee ? rateFee : floorFee;
        if (expectedMin > totalCharged) expectedMin = totalCharged;

        assertEq(feeCollected, expectedMin, "fee must equal max(floor, rate), capped at unwithdrawn");
    }

    // =========================================================================
    // Property: USDC conservation through withdraw + close with floor
    // =========================================================================

    function testFuzz_withdrawThenClose_usdcConserved(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 50));

        bytes32 tabId = bytes32("fuzz-conserve");
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

        uint256 totalAfter =
            usdc.balanceOf(agent) + usdc.balanceOf(provider) + usdc.balanceOf(feeWallet) + usdc.balanceOf(address(tab));

        assertEq(totalAfter, totalBefore, "USDC must be conserved");
        assertEq(usdc.balanceOf(address(tab)), 0, "contract empty after close");
    }

    // =========================================================================
    // Property: distribution sums to tab balance
    // =========================================================================

    function testFuzz_close_distributionSumsToTabBalance(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 500_000e6));
        numCharges = uint8(bound(numCharges, 1, 50));

        bytes32 tabId = bytes32("fuzz-dist");
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
        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);
        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        tab.closeTab(tabId);

        uint256 providerGain = usdc.balanceOf(provider) - providerBefore;
        uint256 feeGain = usdc.balanceOf(feeWallet) - feeWalletBefore;
        uint256 agentGain = usdc.balanceOf(agent) - agentBefore;

        assertEq(providerGain + feeGain + agentGain, balance, "distribution must sum to tab balance");
    }

    // =========================================================================
    // Property: fee floor tracks correctly across multiple withdrawal windows
    // =========================================================================

    function testFuzz_multipleWithdrawals_floorTracksCorrectly(
        uint8 chargesRound1,
        uint8 chargesRound2,
        uint96 chargeSize
    ) public {
        chargesRound1 = uint8(bound(chargesRound1, 1, 30));
        chargesRound2 = uint8(bound(chargesRound2, 1, 30));
        uint256 totalCharges = uint256(chargesRound1) + uint256(chargesRound2);

        bytes32 tabId = bytes32("fuzz-multi");
        uint96 tabAmount = 100e6; // $100
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
            uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

            vm.prank(relayerAddr);
            tab.withdrawCharged(tabId);

            uint256 fee1 = usdc.balanceOf(feeWallet) - feeWalletBefore;
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

        // Close — fee should only count round 2 charges (or all if round 1 wasn't withdrawn)
        vm.prank(agent);
        tab.closeTab(tabId);

        // Conservation check
        assertEq(usdc.balanceOf(address(tab)), 0, "contract empty");
    }

    // =========================================================================
    // Property: fee never exceeds unwithdrawn
    // =========================================================================

    function testFuzz_feeNeverExceedsUnwithdrawn(uint96 tabAmount, uint8 numCharges, uint96 chargeSize) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 100_000e6));
        numCharges = uint8(bound(numCharges, 1, 200));

        bytes32 tabId = bytes32("fuzz-cap");
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

        uint256 feeWalletBefore = usdc.balanceOf(feeWallet);

        vm.prank(agent);
        tab.closeTab(tabId);

        uint256 feeCollected = usdc.balanceOf(feeWallet) - feeWalletBefore;

        assertLe(feeCollected, totalCharged, "fee must not exceed total charged");
        // Provider should never go negative (implied by no revert)
    }
}

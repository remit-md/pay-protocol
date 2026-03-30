// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCTabFuzz
/// @notice Minimal ERC-20 mock for PayTab fuzz testing.
contract MockUSDCTabFuzz {
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

/// @title PayTabFuzzTest
/// @notice Property-based fuzz tests for PayTab.sol — openTab
contract PayTabFuzzTest is Test {
    PayTab internal payTab;
    MockUSDCTabFuzz internal usdc;

    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    uint96 constant MIN_TAB = PayTypes.MIN_TAB_AMOUNT;
    uint96 constant MIN_ACT_FEE = PayTypes.MIN_ACTIVATION_FEE;

    function setUp() public {
        usdc = new MockUSDCTabFuzz();
        payTab = new PayTab(address(usdc), feeWallet, relayer);
    }

    // =========================================================================
    // Property: USDC conservation — agent loses exactly `amount`
    // =========================================================================

    /// @dev For any valid openTab, agent_loss == contract_gain + feeWallet_gain == amount.
    function testFuzz_usdcConserved(uint96 amount, uint96 maxCharge, uint64 salt) public {
        amount = uint96(bound(amount, MIN_TAB, type(uint96).max));
        maxCharge = uint96(bound(maxCharge, 1, type(uint96).max));
        bytes32 tabId = bytes32(uint256(salt));

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(payTab), amount);

        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        payTab.openTab(tabId, provider, amount, maxCharge);

        uint256 agentLoss = agentBefore - usdc.balanceOf(agent);
        uint256 contractGain = usdc.balanceOf(address(payTab));
        uint256 feeGain = usdc.balanceOf(feeWallet);

        assertEq(agentLoss, amount, "agent must lose exactly the tab amount");
        assertEq(contractGain + feeGain, amount, "contract + feeWallet must receive exactly the tab amount");
    }

    // =========================================================================
    // Property: activation fee bounds
    // =========================================================================

    /// @dev Activation fee is always >= MIN_ACTIVATION_FEE and <= amount.
    function testFuzz_activationFeeBounds(uint96 amount, uint64 salt) public {
        amount = uint96(bound(amount, MIN_TAB, type(uint96).max));
        bytes32 tabId = bytes32(uint256(salt));

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(payTab), amount);

        vm.prank(agent);
        payTab.openTab(tabId, provider, amount, 1);

        PayTypes.Tab memory t = payTab.getTab(tabId);

        assertGe(t.activationFee, MIN_ACT_FEE, "fee must be >= MIN_ACTIVATION_FEE");
        assertLt(t.activationFee, amount, "fee must be < amount");
    }

    // =========================================================================
    // Property: tab balance + activation fee == original amount
    // =========================================================================

    /// @dev The tab balance plus the activation fee always equals the original deposit amount.
    function testFuzz_balancePlusFeeEqualsAmount(uint96 amount, uint64 salt) public {
        amount = uint96(bound(amount, MIN_TAB, type(uint96).max));
        bytes32 tabId = bytes32(uint256(salt));

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(payTab), amount);

        vm.prank(agent);
        payTab.openTab(tabId, provider, amount, 1);

        PayTypes.Tab memory t = payTab.getTab(tabId);
        assertEq(t.amount + t.activationFee, amount, "balance + fee must equal deposit");
    }

    // =========================================================================
    // Property: activation fee formula correctness
    // =========================================================================

    /// @dev Activation fee == max(MIN_ACTIVATION_FEE, amount / 100) for all valid amounts.
    function testFuzz_activationFeeFormula(uint96 amount, uint64 salt) public {
        amount = uint96(bound(amount, MIN_TAB, type(uint96).max));
        bytes32 tabId = bytes32(uint256(salt));

        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(payTab), amount);

        vm.prank(agent);
        payTab.openTab(tabId, provider, amount, 1);

        PayTypes.Tab memory t = payTab.getTab(tabId);

        uint96 percentFee = amount / 100;
        uint96 expectedFee = percentFee > MIN_ACT_FEE ? percentFee : MIN_ACT_FEE;
        assertEq(t.activationFee, expectedFee, "fee must match max(MIN, 1%)");
    }

    // =========================================================================
    // Property: tab IDs are isolated — no collision
    // =========================================================================

    /// @dev Two different tab IDs never interfere with each other.
    function testFuzz_tabIsolation(uint96 amount1, uint96 amount2, uint64 salt1, uint64 salt2) public {
        amount1 = uint96(bound(amount1, MIN_TAB, 100_000e6));
        amount2 = uint96(bound(amount2, MIN_TAB, 100_000e6));
        vm.assume(salt1 != salt2);

        bytes32 tabId1 = bytes32(uint256(salt1));
        bytes32 tabId2 = bytes32(uint256(salt2));

        usdc.mint(agent, uint256(amount1) + amount2);
        vm.prank(agent);
        usdc.approve(address(payTab), uint256(amount1) + amount2);

        vm.startPrank(agent);
        payTab.openTab(tabId1, provider, amount1, 1);
        payTab.openTab(tabId2, provider, amount2, 1);
        vm.stopPrank();

        PayTypes.Tab memory t1 = payTab.getTab(tabId1);
        PayTypes.Tab memory t2 = payTab.getTab(tabId2);

        assertEq(t1.amount + t1.activationFee, amount1);
        assertEq(t2.amount + t2.activationFee, amount2);
    }

    // =========================================================================
    // Property: openTab and openTabFor produce identical tabs
    // =========================================================================

    /// @dev Both entry points result in the same tab state for the same inputs.
    function testFuzz_directAndForIdentical(uint96 amount, uint96 maxCharge) public {
        amount = uint96(bound(amount, MIN_TAB, type(uint96).max / 2));
        maxCharge = uint96(bound(maxCharge, 1, type(uint96).max));

        bytes32 id1 = bytes32("direct");
        bytes32 id2 = bytes32("for");

        usdc.mint(agent, uint256(amount) * 2);
        vm.prank(agent);
        usdc.approve(address(payTab), uint256(amount) * 2);

        vm.prank(agent);
        payTab.openTab(id1, provider, amount, maxCharge);

        vm.prank(relayer);
        payTab.openTabFor(agent, id2, provider, amount, maxCharge);

        PayTypes.Tab memory t1 = payTab.getTab(id1);
        PayTypes.Tab memory t2 = payTab.getTab(id2);

        assertEq(t1.agent, t2.agent);
        assertEq(t1.amount, t2.amount);
        assertEq(t1.provider, t2.provider);
        assertEq(t1.totalCharged, t2.totalCharged);
        assertEq(t1.maxChargePerCall, t2.maxChargePerCall);
        assertEq(t1.activationFee, t2.activationFee);
        assertEq(uint8(t1.status), uint8(t2.status));
        assertEq(t1.chargeCount, t2.chargeCount);
    }
}

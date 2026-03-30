// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";
import {PayErrors} from "../src/libraries/PayErrors.sol";
import {PayEvents} from "../src/libraries/PayEvents.sol";

/// @title MockUSDCTab
/// @notice Minimal ERC-20 mock for PayTab testing.
contract MockUSDCTab {
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

/// @title PayTabTest
/// @notice Unit tests for PayTab.sol — openTab + openTabFor + getTab
contract PayTabTest is Test {
    PayTab internal tab;
    MockUSDCTab internal usdc;

    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");

    uint96 constant MIN_TAB = PayTypes.MIN_TAB_AMOUNT; // $5.00
    uint96 constant MIN_ACT_FEE = PayTypes.MIN_ACTIVATION_FEE; // $0.10

    bytes32 constant TAB_ID = bytes32("tab-001");

    function setUp() public {
        usdc = new MockUSDCTab();
        tab = new PayTab(address(usdc), feeWallet, relayer);

        // Fund agent and approve PayTab
        usdc.mint(agent, 1_000_000e6);
        vm.prank(agent);
        usdc.approve(address(tab), type(uint256).max);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(address(tab.usdc()), address(usdc));
        assertEq(tab.feeWallet(), feeWallet);
        assertEq(tab.relayer(), relayer);
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new PayTab(address(0), feeWallet, relayer);
    }

    function test_constructor_revertsOnZeroFeeWallet() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new PayTab(address(usdc), address(0), relayer);
    }

    function test_constructor_revertsOnZeroRelayer() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        new PayTab(address(usdc), feeWallet, address(0));
    }

    // =========================================================================
    // openTab — happy path
    // =========================================================================

    function test_openTab_createsTab() public {
        uint96 amount = 20e6; // $20
        uint96 maxCharge = 500_000; // $0.50

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, maxCharge);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.agent, agent);
        assertEq(t.provider, provider);
        assertEq(t.maxChargePerCall, maxCharge);
        assertEq(t.totalCharged, 0);
        assertEq(uint8(t.status), uint8(PayTypes.TabStatus.Active));
    }

    function test_openTab_activationFee_atMinimum() public {
        // $5.00 → 1% = $0.05, but min is $0.10. So fee = $0.10.
        uint96 amount = 5e6;
        uint96 expectedFee = MIN_ACT_FEE; // $0.10
        uint96 expectedBalance = amount - expectedFee;

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, 100_000);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.amount, expectedBalance);
        assertEq(t.activationFee, expectedFee);
    }

    function test_openTab_activationFee_onePercent() public {
        // $20.00 → 1% = $0.20 > $0.10 min. So fee = $0.20.
        uint96 amount = 20e6;
        uint96 expectedFee = amount / 100; // $0.20
        uint96 expectedBalance = amount - expectedFee;

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, 100_000);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.amount, expectedBalance);
        assertEq(t.activationFee, expectedFee);
    }

    function test_openTab_activationFee_exactBreakeven() public {
        // At $10.00, 1% = $0.10 = MIN_ACT_FEE. Either path gives same result.
        uint96 amount = 10e6;
        uint96 expectedFee = MIN_ACT_FEE;

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, 100_000);

        assertEq(tab.getTab(TAB_ID).activationFee, expectedFee);
    }

    function test_openTab_transfersUsdc() public {
        uint96 amount = 50e6; // $50
        uint96 expectedFee = amount / 100; // $0.50
        uint96 expectedBalance = amount - expectedFee;

        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, 1e6);

        // Agent loses full amount
        assertEq(usdc.balanceOf(agent), agentBefore - amount);
        // Contract holds tab balance
        assertEq(usdc.balanceOf(address(tab)), expectedBalance);
        // Fee wallet gets activation fee
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
    }

    function test_openTab_emitsEvent() public {
        uint96 amount = 20e6;
        uint96 expectedFee = amount / 100;
        uint96 expectedBalance = amount - expectedFee;
        uint96 maxCharge = 500_000;

        vm.expectEmit(true, true, true, true);
        emit PayEvents.TabOpened(TAB_ID, agent, provider, expectedBalance, maxCharge, expectedFee);

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, maxCharge);
    }

    function test_openTab_minimumAmount() public {
        vm.prank(agent);
        tab.openTab(TAB_ID, provider, MIN_TAB, 100_000);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.agent, agent);
        assertEq(uint8(t.status), uint8(PayTypes.TabStatus.Active));
    }

    function test_openTab_largeAmount() public {
        uint96 amount = 1_000_000e6; // $1M
        usdc.mint(agent, amount); // extra funds

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, 10e6);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.activationFee, amount / 100); // $10,000
        assertEq(t.amount, amount - amount / 100);
    }

    // =========================================================================
    // openTab — reverts
    // =========================================================================

    function test_openTab_revertsOnZeroProvider() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(agent);
        tab.openTab(TAB_ID, address(0), 10e6, 100_000);
    }

    function test_openTab_revertsOnSelfPayment() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.SelfPayment.selector, agent));
        vm.prank(agent);
        tab.openTab(TAB_ID, agent, 10e6, 100_000);
    }

    function test_openTab_revertsOnBelowMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, uint96(4_999_999), MIN_TAB));
        vm.prank(agent);
        tab.openTab(TAB_ID, provider, 4_999_999, 100_000);
    }

    function test_openTab_revertsOnZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.BelowMinimum.selector, uint96(0), MIN_TAB));
        vm.prank(agent);
        tab.openTab(TAB_ID, provider, 0, 100_000);
    }

    function test_openTab_revertsOnZeroMaxCharge() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAmount.selector));
        vm.prank(agent);
        tab.openTab(TAB_ID, provider, 10e6, 0);
    }

    function test_openTab_revertsOnDuplicateTabId() public {
        vm.startPrank(agent);
        tab.openTab(TAB_ID, provider, 10e6, 100_000);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabAlreadyExists.selector, TAB_ID));
        tab.openTab(TAB_ID, provider, 10e6, 100_000);
        vm.stopPrank();
    }

    function test_openTab_revertsOnInsufficientBalance() public {
        address broke = makeAddr("broke");
        vm.prank(broke);
        usdc.approve(address(tab), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TransferFailed.selector));
        vm.prank(broke);
        tab.openTab(TAB_ID, provider, 10e6, 100_000);
    }

    function test_openTab_revertsOnInsufficientAllowance() public {
        address noApproval = makeAddr("noApproval");
        usdc.mint(noApproval, 100e6);

        vm.expectRevert(abi.encodeWithSelector(PayErrors.TransferFailed.selector));
        vm.prank(noApproval);
        tab.openTab(TAB_ID, provider, 10e6, 100_000);
    }

    // =========================================================================
    // openTabFor — happy path
    // =========================================================================

    function test_openTabFor_createsTab() public {
        uint96 amount = 30e6;

        vm.prank(relayer);
        tab.openTabFor(agent, TAB_ID, provider, amount, 1e6);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.agent, agent);
        assertEq(t.provider, provider);
    }

    function test_openTabFor_correctTransfers() public {
        uint96 amount = 25e6;
        uint96 expectedFee = amount / 100;
        uint96 expectedBalance = amount - expectedFee;

        uint256 agentBefore = usdc.balanceOf(agent);

        vm.prank(relayer);
        tab.openTabFor(agent, TAB_ID, provider, amount, 500_000);

        assertEq(usdc.balanceOf(agent), agentBefore - amount);
        assertEq(usdc.balanceOf(address(tab)), expectedBalance);
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
    }

    // =========================================================================
    // openTabFor — reverts
    // =========================================================================

    function test_openTabFor_revertsForNonRelayer() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tab.openTabFor(agent, TAB_ID, provider, 10e6, 100_000);
    }

    function test_openTabFor_revertsOnZeroAgent() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.ZeroAddress.selector));
        vm.prank(relayer);
        tab.openTabFor(address(0), TAB_ID, provider, 10e6, 100_000);
    }

    // =========================================================================
    // getTab
    // =========================================================================

    function test_getTab_revertsOnNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(PayErrors.TabNotFound.selector, bytes32("nonexistent")));
        tab.getTab(bytes32("nonexistent"));
    }

    function test_getTab_returnsCorrectData() public {
        uint96 amount = 15e6;
        uint96 maxCharge = 200_000;
        uint96 expectedFee = amount / 100;
        uint96 expectedBalance = amount - expectedFee;

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, maxCharge);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.agent, agent);
        assertEq(t.amount, expectedBalance);
        assertEq(t.provider, provider);
        assertEq(t.totalCharged, 0);
        assertEq(t.maxChargePerCall, maxCharge);
        assertEq(t.activationFee, expectedFee);
        assertEq(uint8(t.status), uint8(PayTypes.TabStatus.Active));
    }

    // =========================================================================
    // Multiple tabs
    // =========================================================================

    function test_multipleTabs_independentStorage() public {
        bytes32 tab1 = bytes32("tab-001");
        bytes32 tab2 = bytes32("tab-002");

        vm.startPrank(agent);
        tab.openTab(tab1, provider, 10e6, 100_000);
        tab.openTab(tab2, provider, 20e6, 500_000);
        vm.stopPrank();

        PayTypes.Tab memory t1 = tab.getTab(tab1);
        PayTypes.Tab memory t2 = tab.getTab(tab2);

        assertEq(t1.maxChargePerCall, 100_000);
        assertEq(t2.maxChargePerCall, 500_000);
        assertTrue(t1.amount != t2.amount);
    }

    function test_multipleTabs_differentProviders() public {
        address provider2 = makeAddr("provider2");

        vm.startPrank(agent);
        tab.openTab(bytes32("t1"), provider, 10e6, 100_000);
        tab.openTab(bytes32("t2"), provider2, 10e6, 100_000);
        vm.stopPrank();

        assertEq(tab.getTab(bytes32("t1")).provider, provider);
        assertEq(tab.getTab(bytes32("t2")).provider, provider2);
    }

    function test_multipleTabs_differentAgents() public {
        address agent2 = makeAddr("agent2");
        usdc.mint(agent2, 100e6);
        vm.prank(agent2);
        usdc.approve(address(tab), type(uint256).max);

        vm.prank(agent);
        tab.openTab(bytes32("t1"), provider, 10e6, 100_000);

        vm.prank(agent2);
        tab.openTab(bytes32("t2"), provider, 10e6, 100_000);

        assertEq(tab.getTab(bytes32("t1")).agent, agent);
        assertEq(tab.getTab(bytes32("t2")).agent, agent2);
    }

    // =========================================================================
    // USDC conservation
    // =========================================================================

    function test_usdcConserved_onOpen() public {
        uint96 amount = 77e6; // non-round number

        uint256 totalBefore = usdc.balanceOf(agent) + usdc.balanceOf(address(tab)) + usdc.balanceOf(feeWallet);

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, 1e6);

        uint256 totalAfter = usdc.balanceOf(agent) + usdc.balanceOf(address(tab)) + usdc.balanceOf(feeWallet);

        assertEq(totalAfter, totalBefore, "USDC must be conserved");
    }

    function test_tabBalancePlusFee_equalsAmount() public {
        uint96 amount = 123_456_789; // ~$123.46

        vm.prank(agent);
        tab.openTab(TAB_ID, provider, amount, 1e6);

        PayTypes.Tab memory t = tab.getTab(TAB_ID);
        assertEq(t.amount + t.activationFee, amount, "balance + fee must equal amount");
    }
}

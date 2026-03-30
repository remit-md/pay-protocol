// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayTab} from "../src/PayTab.sol";
import {PayFee} from "../src/PayFee.sol";
import {PayTypes} from "../src/libraries/PayTypes.sol";

/// @title MockUSDCChargeFuzz
/// @notice Minimal ERC-20 mock for chargeTab fuzz testing.
contract MockUSDCChargeFuzz {
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

/// @title PayTabChargeFuzzTest
/// @notice Property-based fuzz tests for PayTab.chargeTab
contract PayTabChargeFuzzTest is Test {
    PayTab internal payTab;
    PayFee internal fee;
    MockUSDCChargeFuzz internal usdc;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    address internal feeWallet = makeAddr("feeWallet");
    address internal agent = makeAddr("agent");
    address internal provider = makeAddr("provider");

    uint96 constant MIN_TAB = PayTypes.MIN_TAB_AMOUNT;

    function setUp() public {
        usdc = new MockUSDCChargeFuzz();

        PayFee feeImpl = new PayFee();
        bytes memory data = abi.encodeCall(feeImpl.initialize, (owner));
        fee = PayFee(address(new ERC1967Proxy(address(feeImpl), data)));

        payTab = new PayTab(address(usdc), address(fee), feeWallet, relayer);

        vm.prank(owner);
        fee.authorizeCaller(address(payTab));
    }

    /// @dev Helper: open a tab and return its balance after activation fee.
    function _openTab(bytes32 tabId, uint96 amount, uint96 maxCharge) internal returns (uint96 balance) {
        usdc.mint(agent, amount);
        vm.prank(agent);
        usdc.approve(address(payTab), amount);
        vm.prank(agent);
        payTab.openTab(tabId, provider, amount, maxCharge);
        balance = payTab.getTab(tabId).amount;
    }

    // =========================================================================
    // Property: amount + totalCharged == original balance (invariant)
    // =========================================================================

    /// @dev After any single charge, balance + totalCharged == original balance.
    function testFuzz_balanceInvariant_singleCharge(uint96 tabAmount, uint96 maxCharge, uint96 charge) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));
        maxCharge = uint96(bound(maxCharge, 1, tabAmount));

        bytes32 tabId = bytes32("inv-1");
        uint96 balance = _openTab(tabId, tabAmount, maxCharge);

        charge = uint96(bound(charge, 1, balance < maxCharge ? balance : maxCharge));

        vm.prank(relayer);
        payTab.chargeTab(tabId, charge);

        PayTypes.Tab memory t = payTab.getTab(tabId);
        assertEq(t.amount + t.totalCharged, balance, "invariant: amount + totalCharged == original balance");
    }

    // =========================================================================
    // Property: chargeCount increments by 1 per charge
    // =========================================================================

    /// @dev After N charges, chargeCount == N.
    function testFuzz_chargeCountIncrements(uint96 tabAmount, uint96 maxCharge, uint8 numCharges) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 100_000e6));
        maxCharge = uint96(bound(maxCharge, 1, tabAmount));
        numCharges = uint8(bound(numCharges, 1, 20));

        bytes32 tabId = bytes32("cnt-1");
        uint96 balance = _openTab(tabId, tabAmount, maxCharge);

        // Determine safe charge amount: min of maxCharge, balance / numCharges (avoid running out)
        uint96 safeCharge = uint96(balance / numCharges);
        if (safeCharge > maxCharge) safeCharge = maxCharge;
        if (safeCharge == 0) return; // skip if tab too small for this many charges

        vm.startPrank(relayer);
        for (uint8 i = 0; i < numCharges; i++) {
            payTab.chargeTab(tabId, safeCharge);
        }
        vm.stopPrank();

        assertEq(payTab.getTab(tabId).chargeCount, numCharges, "chargeCount must equal number of charges");
    }

    // =========================================================================
    // Property: no USDC moves during charge (pure SSTORE)
    // =========================================================================

    /// @dev Contract USDC balance is unchanged after any number of charges.
    function testFuzz_noUsdcTransferOnCharge(uint96 tabAmount, uint96 charge) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        bytes32 tabId = bytes32("no-xfer");
        uint96 balance = _openTab(tabId, tabAmount, tabAmount); // maxCharge = tabAmount (no limit issue)

        charge = uint96(bound(charge, 1, balance));

        uint256 contractBefore = usdc.balanceOf(address(payTab));

        vm.prank(relayer);
        payTab.chargeTab(tabId, charge);

        assertEq(usdc.balanceOf(address(payTab)), contractBefore, "contract USDC must not change on charge");
    }

    // =========================================================================
    // Property: charge never exceeds maxChargePerCall
    // =========================================================================

    /// @dev Any charge > maxChargePerCall reverts.
    function testFuzz_maxChargeEnforced(uint96 tabAmount, uint96 maxCharge, uint96 charge) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));
        maxCharge = uint96(bound(maxCharge, 1, tabAmount));

        bytes32 tabId = bytes32("max-enf");
        _openTab(tabId, tabAmount, maxCharge);

        charge = uint96(bound(charge, maxCharge + 1, type(uint96).max));

        vm.expectRevert();
        vm.prank(relayer);
        payTab.chargeTab(tabId, charge);
    }

    // =========================================================================
    // Property: charge never exceeds remaining balance
    // =========================================================================

    /// @dev Any charge > remaining balance reverts (when within maxCharge).
    function testFuzz_balanceBoundEnforced(uint96 tabAmount, uint96 charge) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        bytes32 tabId = bytes32("bal-enf");
        uint96 balance = _openTab(tabId, tabAmount, type(uint96).max); // huge maxCharge so it's not the bottleneck

        charge = uint96(bound(charge, balance + 1, type(uint96).max));

        vm.expectRevert();
        vm.prank(relayer);
        payTab.chargeTab(tabId, charge);
    }

    // =========================================================================
    // Property: totalCharged monotonically increases
    // =========================================================================

    /// @dev totalCharged after each charge is >= totalCharged before.
    function testFuzz_totalChargedMonotonic(uint96 tabAmount, uint96 charge1, uint96 charge2) public {
        tabAmount = uint96(bound(tabAmount, MIN_TAB, 1_000_000e6));

        bytes32 tabId = bytes32("mono");
        uint96 balance = _openTab(tabId, tabAmount, tabAmount);

        charge1 = uint96(bound(charge1, 1, balance / 2));
        vm.prank(relayer);
        payTab.chargeTab(tabId, charge1);
        uint96 tc1 = payTab.getTab(tabId).totalCharged;

        uint96 remaining = payTab.getTab(tabId).amount;
        if (remaining == 0) return;
        charge2 = uint96(bound(charge2, 1, remaining < tabAmount ? remaining : tabAmount));

        vm.prank(relayer);
        payTab.chargeTab(tabId, charge2);
        uint96 tc2 = payTab.getTab(tabId).totalCharged;

        assertGe(tc2, tc1, "totalCharged must be monotonically non-decreasing");
    }
}

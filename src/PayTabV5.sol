// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPayTab} from "./interfaces/IPayTab.sol";
import {IPayTabV2} from "./interfaces/IPayTabV2.sol";
import {IPayFee} from "./interfaces/IPayFee.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {PayTypes} from "./libraries/PayTypes.sol";
import {PayErrors} from "./libraries/PayErrors.sol";
import {PayEvents} from "./libraries/PayEvents.sol";

/// @title PayTabV5
/// @notice Pre-funded metered account — gas-optimized via fee accumulation,
///         transient reentrancy guard, and 4-slot struct packing.
/// @dev IMMUTABLE -- no proxy, no admin key, no upgrade path. Holds USDC.
///
///      Changes from V4:
///        - Fee accumulation: fees stored in _accumulatedFees, swept via sweepFees().
///          Eliminates one USDC transfer per withdrawCharged/closeTab/openTab.
///        - ReentrancyGuardTransient: TSTORE/TLOAD (100 gas) vs SSTORE/SLOAD (5000 gas).
///        - TabV5 struct: 4 slots (chargeCount uint32, chargeCountAtLastWithdraw merged in).
///          Eliminates separate _chargeCountAtLastWithdrawal mapping.
///
///      State machine (unchanged):
///        nonexistent -> active (via openTab)
///        active -> active (via chargeTab, settleCharges, topUpTab, withdrawCharged)
///        active -> closed (via closeTab)
contract PayTabV5 is IPayTabV2, ReentrancyGuardTransient {
    // =========================================================================
    // Immutable state
    // =========================================================================

    IUSDC public immutable usdc;
    IPayFee public immutable payFee;
    address public immutable feeWallet;
    address public immutable relayer;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Tab storage. tabId -> TabV5 struct (4 slots per tab).
    mapping(bytes32 => PayTypes.TabV5) internal _tabs;

    /// @notice Accumulated fees pending sweep to feeWallet.
    uint96 internal _accumulatedFees;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address usdc_, address payFee_, address feeWallet_, address relayer_) {
        if (usdc_ == address(0)) revert PayErrors.ZeroAddress();
        if (payFee_ == address(0)) revert PayErrors.ZeroAddress();
        if (feeWallet_ == address(0)) revert PayErrors.ZeroAddress();
        if (relayer_ == address(0)) revert PayErrors.ZeroAddress();

        usdc = IUSDC(usdc_);
        payFee = IPayFee(payFee_);
        feeWallet = feeWallet_;
        relayer = relayer_;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert PayErrors.Unauthorized(msg.sender);
        _;
    }

    // =========================================================================
    // sweepFees -- batch transfer accumulated fees to feeWallet
    // =========================================================================

    /// @notice Transfer all accumulated fees to feeWallet in one USDC transfer.
    /// @dev Permissionless -- funds always go to the immutable feeWallet.
    function sweepFees() external nonReentrant {
        uint96 fees = _accumulatedFees;
        if (fees == 0) revert PayErrors.ZeroAmount();

        _accumulatedFees = 0;

        bool sent = usdc.transfer(feeWallet, fees);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.FeeSwept(fees);
    }

    /// @notice Current accumulated fees pending sweep.
    function accumulatedFees() external view returns (uint96) {
        return _accumulatedFees;
    }

    // =========================================================================
    // settleCharges -- batch SSTORE (from V2)
    // =========================================================================

    /// @inheritdoc IPayTabV2
    function settleCharges(bytes32 tabId, uint96 totalAmount, uint32 chargeCount, uint96 maxSingleCharge)
        external
        onlyRelayer
    {
        PayTypes.TabV5 storage t = _tabs[tabId];

        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (totalAmount == 0) revert PayErrors.ZeroAmount();
        if (totalAmount > t.amount) revert PayErrors.InsufficientBalance(tabId, totalAmount, t.amount);
        if (maxSingleCharge > t.maxChargePerCall) {
            revert PayErrors.ChargeLimitExceeded(tabId, maxSingleCharge, t.maxChargePerCall);
        }

        t.amount -= totalAmount;
        t.totalCharged += totalAmount;
        t.chargeCount += chargeCount;

        emit PayEvents.TabSettled(tabId, totalAmount, chargeCount, maxSingleCharge, t.amount, t.chargeCount);
    }

    // =========================================================================
    // openTab
    // =========================================================================

    /// @inheritdoc IPayTab
    function openTab(bytes32 tabId, address provider, uint96 amount, uint96 maxChargePerCall) external nonReentrant {
        _openTab(msg.sender, tabId, provider, amount, maxChargePerCall);
    }

    /// @inheritdoc IPayTab
    function openTabFor(address agent, bytes32 tabId, address provider, uint96 amount, uint96 maxChargePerCall)
        external
        nonReentrant
        onlyRelayer
    {
        if (agent == address(0)) revert PayErrors.ZeroAddress();
        _openTab(agent, tabId, provider, amount, maxChargePerCall);
    }

    // =========================================================================
    // chargeTab
    // =========================================================================

    /// @inheritdoc IPayTab
    function chargeTab(bytes32 tabId, uint96 amount) external onlyRelayer {
        PayTypes.TabV5 storage t = _tabs[tabId];

        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (amount == 0) revert PayErrors.ZeroAmount();
        if (amount > t.maxChargePerCall) revert PayErrors.ChargeLimitExceeded(tabId, amount, t.maxChargePerCall);
        if (amount > t.amount) revert PayErrors.InsufficientBalance(tabId, amount, t.amount);

        t.amount -= amount;
        t.totalCharged += amount;
        t.chargeCount += 1;

        emit PayEvents.TabCharged(tabId, amount, t.amount, t.chargeCount);
    }

    // =========================================================================
    // topUpTab
    // =========================================================================

    /// @inheritdoc IPayTab
    function topUpTab(bytes32 tabId, uint96 amount) external nonReentrant {
        _topUp(msg.sender, tabId, amount);
    }

    /// @inheritdoc IPayTab
    function topUpTabFor(address agent, bytes32 tabId, uint96 amount) external nonReentrant onlyRelayer {
        if (agent == address(0)) revert PayErrors.ZeroAddress();
        _topUp(agent, tabId, amount);
    }

    // =========================================================================
    // withdrawCharged
    // =========================================================================

    /// @inheritdoc IPayTab
    /// @dev onlyRelayer. Fee accumulated (not transferred). One USDC transfer (provider payout).
    function withdrawCharged(bytes32 tabId) external nonReentrant onlyRelayer {
        PayTypes.TabV5 storage t = _tabs[tabId];

        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);

        uint96 unwithdrawn = t.totalCharged - t.totalWithdrawn;
        if (unwithdrawn == 0) revert PayErrors.NothingToWithdraw(tabId);
        if (unwithdrawn < PayTypes.MIN_WITHDRAW_AMOUNT) {
            revert PayErrors.BelowMinimum(unwithdrawn, PayTypes.MIN_WITHDRAW_AMOUNT);
        }

        uint96 fee = _calculateFeeWithFloor(t.provider, unwithdrawn, t.chargeCount, t.chargeCountAtLastWithdraw);
        uint96 payout = unwithdrawn - fee;

        // --- Effects ---
        t.totalWithdrawn += unwithdrawn;
        t.chargeCountAtLastWithdraw = t.chargeCount;
        _accumulatedFees += fee;
        payFee.recordTransaction(t.provider, unwithdrawn);

        // --- Interactions ---
        if (payout > 0) {
            bool sent = usdc.transfer(t.provider, payout);
            if (!sent) revert PayErrors.TransferFailed();
        }

        emit PayEvents.TabWithdrawn(tabId, payout, fee, t.totalWithdrawn);
    }

    // =========================================================================
    // closeTab
    // =========================================================================

    /// @inheritdoc IPayTab
    function closeTab(bytes32 tabId) external nonReentrant {
        PayTypes.TabV5 storage t = _tabs[tabId];

        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (msg.sender != t.agent && msg.sender != t.provider && msg.sender != relayer) {
            revert PayErrors.Unauthorized(msg.sender);
        }

        address agent = t.agent;
        address provider = t.provider;
        uint96 totalCharged = t.totalCharged;
        uint96 totalWithdrawn = t.totalWithdrawn;
        uint96 remaining = t.amount;
        uint32 chargeCount = t.chargeCount;
        uint32 chargeCountAtLastWithdraw = t.chargeCountAtLastWithdraw;

        uint96 unwithdrawn = totalCharged - totalWithdrawn;
        uint96 fee = 0;
        uint96 providerPayout = 0;
        if (unwithdrawn > 0) {
            fee = _calculateFeeWithFloor(provider, unwithdrawn, chargeCount, chargeCountAtLastWithdraw);
            providerPayout = unwithdrawn - fee;
        }

        // --- Effects ---
        t.status = PayTypes.TabStatus.Closed;
        t.amount = 0;

        if (fee > 0) {
            _accumulatedFees += fee;
        }
        if (unwithdrawn > 0) {
            payFee.recordTransaction(provider, unwithdrawn);
        }

        // --- Interactions ---
        if (providerPayout > 0) {
            bool sent = usdc.transfer(provider, providerPayout);
            if (!sent) revert PayErrors.TransferFailed();
        }
        if (remaining > 0) {
            bool sent = usdc.transfer(agent, remaining);
            if (!sent) revert PayErrors.TransferFailed();
        }

        emit PayEvents.TabClosed(tabId, totalCharged, providerPayout, fee, remaining);
    }

    // =========================================================================
    // getTab — returns V4-compatible Tab struct for interface compliance
    // =========================================================================

    /// @inheritdoc IPayTab
    function getTab(bytes32 tabId) external view returns (PayTypes.Tab memory tab) {
        PayTypes.TabV5 storage t = _tabs[tabId];
        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        tab = PayTypes.Tab({
            agent: t.agent,
            amount: t.amount,
            provider: t.provider,
            totalCharged: t.totalCharged,
            maxChargePerCall: t.maxChargePerCall,
            activationFee: t.activationFee,
            status: t.status,
            chargeCount: t.chargeCount,
            totalWithdrawn: t.totalWithdrawn
        });
    }

    /// @notice Get V5 tab details including chargeCountAtLastWithdraw.
    function getTabV5(bytes32 tabId) external view returns (PayTypes.TabV5 memory) {
        PayTypes.TabV5 storage t = _tabs[tabId];
        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        return t;
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _openTab(address agent, bytes32 tabId, address provider, uint96 amount, uint96 maxChargePerCall) internal {
        if (provider == address(0)) revert PayErrors.ZeroAddress();
        if (agent == provider) revert PayErrors.SelfPayment(agent);
        if (amount < PayTypes.MIN_TAB_AMOUNT) revert PayErrors.BelowMinimum(amount, PayTypes.MIN_TAB_AMOUNT);
        if (maxChargePerCall == 0) revert PayErrors.ZeroAmount();
        if (_tabs[tabId].agent != address(0)) revert PayErrors.TabAlreadyExists(tabId);

        uint96 activationFee = _calculateActivationFee(amount);
        uint96 tabBalance = amount - activationFee;

        _tabs[tabId] = PayTypes.TabV5({
            agent: agent,
            amount: tabBalance,
            provider: provider,
            totalCharged: 0,
            maxChargePerCall: maxChargePerCall,
            activationFee: activationFee,
            status: PayTypes.TabStatus.Active,
            chargeCount: 0,
            totalWithdrawn: 0,
            chargeCountAtLastWithdraw: 0
        });

        // Single transferFrom for full amount; activation fee accumulated
        _accumulatedFees += activationFee;

        bool sent = usdc.transferFrom(agent, address(this), amount);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.TabOpened(tabId, agent, provider, tabBalance, maxChargePerCall, activationFee);
    }

    function _topUp(address caller, bytes32 tabId, uint96 amount) internal {
        PayTypes.TabV5 storage t = _tabs[tabId];

        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (amount == 0) revert PayErrors.ZeroAmount();
        if (caller != t.agent) revert PayErrors.Unauthorized(caller);

        t.amount += amount;

        bool sent = usdc.transferFrom(caller, address(this), amount);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.TabToppedUp(tabId, amount, t.amount);
    }

    /// @dev Activation fee: max(MIN_ACTIVATION_FEE, amount / 100).
    function _calculateActivationFee(uint96 amount) internal pure returns (uint96) {
        uint96 percentFee = amount / 100;
        return percentFee > PayTypes.MIN_ACTIVATION_FEE ? percentFee : PayTypes.MIN_ACTIVATION_FEE;
    }

    /// @dev Fee with per-charge floor: max(chargesNew * MIN_CHARGE_FEE, unwithdrawn * rateBps / 10_000).
    ///      Capped at unwithdrawn to prevent underflow.
    function _calculateFeeWithFloor(address provider, uint96 unwithdrawn, uint32 chargeCount, uint32 lastWithdrawCount)
        internal
        view
        returns (uint96)
    {
        uint96 rateBps = payFee.getFeeRate(provider);
        uint96 rateFee = uint96((uint256(unwithdrawn) * rateBps) / 10_000);
        uint32 chargesNew = chargeCount - lastWithdrawCount;
        uint96 floorFee = uint96(uint256(chargesNew) * PayTypes.MIN_CHARGE_FEE);
        uint96 fee = rateFee > floorFee ? rateFee : floorFee;
        if (fee > unwithdrawn) fee = unwithdrawn;
        return fee;
    }
}

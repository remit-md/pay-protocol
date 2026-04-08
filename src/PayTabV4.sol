// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPayTab} from "./interfaces/IPayTab.sol";
import {IPayTabV2} from "./interfaces/IPayTabV2.sol";
import {IPayFee} from "./interfaces/IPayFee.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {PayTypes} from "./libraries/PayTypes.sol";
import {PayErrors} from "./libraries/PayErrors.sol";
import {PayEvents} from "./libraries/PayEvents.sol";

/// @title PayTabV4
/// @notice Pre-funded metered account with per-charge fee floor enforcement.
/// @dev IMMUTABLE — no proxy, no admin key, no upgrade path. Holds USDC.
///
///      Changes from v3:
///        - Fee floor: max(chargesNew * MIN_CHARGE_FEE, unwithdrawn * rateBps / 10_000).
///          Ensures micropayment tabs pay at least $0.002 per charge in fees.
///        - New storage: _chargeCountAtLastWithdrawal tracks charges per withdrawal window.
///
///      State machine (unchanged from v3):
///        nonexistent -> active (via openTab)
///        active -> active (via chargeTab, settleCharges, topUpTab, withdrawCharged)
///        active -> closed (via closeTab)
contract PayTabV4 is IPayTabV2, ReentrancyGuard {
    // =========================================================================
    // Immutable state (set once in constructor)
    // =========================================================================

    /// @notice USDC token contract on Base.
    IUSDC public immutable usdc;

    /// @notice Fee calculator (UUPS proxy).
    IPayFee public immutable payFee;

    /// @notice Protocol fee wallet — receives activation fees and processing fees.
    address public immutable feeWallet;

    /// @notice Authorized relayer address.
    address public immutable relayer;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Tab storage. tabId -> Tab struct.
    mapping(bytes32 => PayTypes.Tab) internal _tabs;

    /// @notice Charge count at last withdrawal, per tab.
    /// @dev Used to compute charges-since-last-withdrawal for the fee floor.
    ///      Separate mapping preserves IPayTab interface (getTab returns PayTypes.Tab).
    mapping(bytes32 => uint256) internal _chargeCountAtLastWithdrawal;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploy PayTabV4.
    /// @param usdc_ USDC token address on Base
    /// @param payFee_ PayFee calculator (proxy address)
    /// @param feeWallet_ Protocol fee wallet
    /// @param relayer_ Authorized relayer address
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
    // settleCharges — batch SSTORE (from v2)
    // =========================================================================

    /// @inheritdoc IPayTabV2
    /// @dev Only relayer. No USDC transfer — just SSTORE.
    ///      CEI: checks -> effects -> no interactions.
    ///      ~35K gas regardless of batch size (3 SSTORE updates + 1 event).
    function settleCharges(bytes32 tabId, uint96 totalAmount, uint32 chargeCount, uint96 maxSingleCharge)
        external
        onlyRelayer
    {
        PayTypes.Tab storage t = _tabs[tabId];

        // --- Checks ---
        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (totalAmount == 0) revert PayErrors.ZeroAmount();
        if (totalAmount > t.amount) revert PayErrors.InsufficientBalance(tabId, totalAmount, t.amount);
        if (maxSingleCharge > t.maxChargePerCall) {
            revert PayErrors.ChargeLimitExceeded(tabId, maxSingleCharge, t.maxChargePerCall);
        }

        // --- Effects ---
        t.amount -= totalAmount;
        t.totalCharged += totalAmount;
        t.chargeCount += chargeCount;

        emit PayEvents.TabSettled(tabId, totalAmount, chargeCount, maxSingleCharge, t.amount, t.chargeCount);
    }

    // =========================================================================
    // IPayTab — openTab
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
    // IPayTab — chargeTab (retained for backwards compat / single-charge use)
    // =========================================================================

    /// @inheritdoc IPayTab
    /// @dev Only relayer. No USDC transfer — just SSTORE.
    function chargeTab(bytes32 tabId, uint96 amount) external onlyRelayer {
        PayTypes.Tab storage t = _tabs[tabId];

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
    // IPayTab — topUpTab
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
    // IPayTab — withdrawCharged (scheduled rectification only)
    // =========================================================================

    /// @inheritdoc IPayTab
    /// @dev onlyRelayer (same as v3). Provider gets funds via closeTab or scheduled rectification.
    ///      Fee: max(chargesNew * MIN_CHARGE_FEE, unwithdrawn * rateBps / 10_000), capped at unwithdrawn.
    function withdrawCharged(bytes32 tabId) external nonReentrant onlyRelayer {
        PayTypes.Tab storage t = _tabs[tabId];

        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);

        uint96 unwithdrawn = t.totalCharged - t.totalWithdrawn;
        if (unwithdrawn == 0) revert PayErrors.NothingToWithdraw(tabId);
        if (unwithdrawn < PayTypes.MIN_WITHDRAW_AMOUNT) {
            revert PayErrors.BelowMinimum(unwithdrawn, PayTypes.MIN_WITHDRAW_AMOUNT);
        }

        // Fee with per-charge floor: max(floor, rate-based)
        uint96 fee = _calculateFeeWithFloor(t.provider, unwithdrawn, tabId, t.chargeCount);
        uint96 payout = unwithdrawn - fee;

        // --- Effects ---
        t.totalWithdrawn += unwithdrawn;
        _chargeCountAtLastWithdrawal[tabId] = t.chargeCount;
        payFee.recordTransaction(t.provider, unwithdrawn);

        // --- Interactions ---
        if (payout > 0) {
            bool sent = usdc.transfer(t.provider, payout);
            if (!sent) revert PayErrors.TransferFailed();
        }
        if (fee > 0) {
            bool sent = usdc.transfer(feeWallet, fee);
            if (!sent) revert PayErrors.TransferFailed();
        }

        emit PayEvents.TabWithdrawn(tabId, payout, fee, t.totalWithdrawn);
    }

    // =========================================================================
    // IPayTab — closeTab
    // =========================================================================

    /// @inheritdoc IPayTab
    function closeTab(bytes32 tabId) external nonReentrant {
        PayTypes.Tab storage t = _tabs[tabId];

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
        uint256 chargeCount = t.chargeCount;

        uint96 unwithdrawn = totalCharged - totalWithdrawn;
        uint96 fee = 0;
        uint96 providerPayout = 0;
        if (unwithdrawn > 0) {
            fee = _calculateFeeWithFloor(provider, unwithdrawn, tabId, chargeCount);
            providerPayout = unwithdrawn - fee;
        }

        // --- Effects ---
        t.status = PayTypes.TabStatus.Closed;
        t.amount = 0;

        if (unwithdrawn > 0) {
            payFee.recordTransaction(provider, unwithdrawn);
        }

        // --- Interactions ---
        if (providerPayout > 0) {
            bool sent = usdc.transfer(provider, providerPayout);
            if (!sent) revert PayErrors.TransferFailed();
        }
        if (fee > 0) {
            bool sent = usdc.transfer(feeWallet, fee);
            if (!sent) revert PayErrors.TransferFailed();
        }
        if (remaining > 0) {
            bool sent = usdc.transfer(agent, remaining);
            if (!sent) revert PayErrors.TransferFailed();
        }

        emit PayEvents.TabClosed(tabId, totalCharged, providerPayout, fee, remaining);
    }

    // =========================================================================
    // IPayTab — getTab
    // =========================================================================

    /// @inheritdoc IPayTab
    function getTab(bytes32 tabId) external view returns (PayTypes.Tab memory tab) {
        tab = _tabs[tabId];
        if (tab.agent == address(0)) revert PayErrors.TabNotFound(tabId);
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

        _tabs[tabId] = PayTypes.Tab({
            agent: agent,
            amount: tabBalance,
            provider: provider,
            totalCharged: 0,
            maxChargePerCall: maxChargePerCall,
            activationFee: activationFee,
            status: PayTypes.TabStatus.Active,
            chargeCount: 0,
            totalWithdrawn: 0
        });

        bool sent = usdc.transferFrom(agent, address(this), tabBalance);
        if (!sent) revert PayErrors.TransferFailed();

        sent = usdc.transferFrom(agent, feeWallet, activationFee);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.TabOpened(tabId, agent, provider, tabBalance, maxChargePerCall, activationFee);
    }

    function _topUp(address caller, bytes32 tabId, uint96 amount) internal {
        PayTypes.Tab storage t = _tabs[tabId];

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
    ///      Capped at unwithdrawn to prevent underflow when floor exceeds charged amount.
    ///      This ensures micropayment tabs pay at least $0.002/charge, covering gas costs.
    function _calculateFeeWithFloor(address provider, uint96 unwithdrawn, bytes32 tabId, uint256 chargeCount)
        internal
        view
        returns (uint96)
    {
        uint96 rateBps = payFee.getFeeRate(provider);
        uint96 rateFee = uint96((uint256(unwithdrawn) * rateBps) / 10_000);
        uint256 chargesNew = chargeCount - _chargeCountAtLastWithdrawal[tabId];
        uint96 floorFee = uint96(chargesNew * PayTypes.MIN_CHARGE_FEE);
        uint96 fee = rateFee > floorFee ? rateFee : floorFee;
        if (fee > unwithdrawn) fee = unwithdrawn;
        return fee;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPayTab} from "./interfaces/IPayTab.sol";
import {IPayFee} from "./interfaces/IPayFee.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {PayTypes} from "./libraries/PayTypes.sol";
import {PayErrors} from "./libraries/PayErrors.sol";
import {PayEvents} from "./libraries/PayEvents.sol";

/// @title PayTab
/// @notice Pre-funded metered account. Agent locks USDC, provider charges per use.
/// @dev IMMUTABLE — no proxy, no admin key, no upgrade path. Holds USDC.
///
///      State machine:
///        nonexistent → active (via openTab)
///        active → active (via chargeTab, topUpTab)
///        active → closed (via closeTab)
///
///      Safety properties:
///        - totalCharged must never exceed locked amount
///        - chargeTab amount must never exceed maxChargePerCall
///        - closed tab can never be charged, topped up, or reopened
///        - only agent or provider or relayer can close
///
///      Activation fee: max($0.10, 1% of tab amount). Paid by agent at open, non-refundable.
///      Sent to feeWallet immediately. Tab balance = amount - activationFee.
contract PayTab is IPayTab, ReentrancyGuard {
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

    /// @notice Tab storage. tabId → Tab struct.
    mapping(bytes32 => PayTypes.Tab) internal _tabs;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploy PayTab.
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
    // IPayTab — chargeTab
    // =========================================================================

    /// @inheritdoc IPayTab
    /// @dev Only relayer. No USDC transfer — just SSTORE (~$0.000004 gas).
    ///      CEI: checks → effects → no interactions.
    function chargeTab(bytes32 tabId, uint96 amount) external onlyRelayer {
        PayTypes.Tab storage t = _tabs[tabId];

        // --- Checks ---
        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (amount == 0) revert PayErrors.ZeroAmount();
        if (amount > t.maxChargePerCall) revert PayErrors.ChargeLimitExceeded(tabId, amount, t.maxChargePerCall);
        if (amount > t.amount) revert PayErrors.InsufficientBalance(tabId, amount, t.amount);

        // --- Effects ---
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
    // IPayTab — withdrawCharged
    // =========================================================================

    /// @inheritdoc IPayTab
    /// @dev CEI: checks → effects (update totalWithdrawn + volume) → interactions (USDC transfers).
    ///      Withdraws all unwithdrawn charges minus processing fee. Tab stays open.
    function withdrawCharged(bytes32 tabId) external nonReentrant {
        PayTypes.Tab storage t = _tabs[tabId];

        // --- Checks ---
        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (msg.sender != t.provider && msg.sender != relayer) {
            revert PayErrors.Unauthorized(msg.sender);
        }

        uint96 unwithdrawn = t.totalCharged - t.totalWithdrawn;
        if (unwithdrawn == 0) revert PayErrors.NothingToWithdraw(tabId);

        // Calculate fee on the unwithdrawn amount
        uint96 rateBps = payFee.getFeeRate(t.provider);
        uint96 fee = uint96((uint256(unwithdrawn) * rateBps) / 10_000);
        uint96 payout = unwithdrawn - fee;

        // --- Effects ---
        t.totalWithdrawn += unwithdrawn;

        // Record volume for provider
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
    /// @dev CEI: checks → effects (status + volume) → interactions (USDC transfers).
    ///      Distribution: provider gets unwithdrawn charges minus fee, fee wallet gets fee, agent gets remaining.
    ///      Funds already paid out via withdrawCharged are excluded.
    function closeTab(bytes32 tabId) external nonReentrant {
        PayTypes.Tab storage t = _tabs[tabId];

        // --- Checks ---
        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (msg.sender != t.agent && msg.sender != t.provider && msg.sender != relayer) {
            revert PayErrors.Unauthorized(msg.sender);
        }

        // Snapshot values before modifying storage
        address agent = t.agent;
        address provider = t.provider;
        uint96 totalCharged = t.totalCharged;
        uint96 totalWithdrawn = t.totalWithdrawn;
        uint96 remaining = t.amount;

        // Calculate fee only on unwithdrawn charges (withdrawn portion already had fee deducted)
        uint96 unwithdrawn = totalCharged - totalWithdrawn;
        uint96 fee = 0;
        uint96 providerPayout = 0;
        if (unwithdrawn > 0) {
            uint96 rateBps = payFee.getFeeRate(provider);
            fee = uint96((uint256(unwithdrawn) * rateBps) / 10_000);
            providerPayout = unwithdrawn - fee;
        }

        // --- Effects ---
        t.status = PayTypes.TabStatus.Closed;
        t.amount = 0;

        // Record volume only for the unwithdrawn portion (withdrawn portion already recorded)
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

    /// @dev Core openTab logic. CEI: checks → effects (store tab) → interactions (USDC transfers).
    function _openTab(address agent, bytes32 tabId, address provider, uint96 amount, uint96 maxChargePerCall) internal {
        // --- Checks ---
        if (provider == address(0)) revert PayErrors.ZeroAddress();
        if (agent == provider) revert PayErrors.SelfPayment(agent);
        if (amount < PayTypes.MIN_TAB_AMOUNT) revert PayErrors.BelowMinimum(amount, PayTypes.MIN_TAB_AMOUNT);
        if (maxChargePerCall == 0) revert PayErrors.ZeroAmount();
        if (_tabs[tabId].agent != address(0)) revert PayErrors.TabAlreadyExists(tabId);

        // Calculate activation fee: max($0.10, 1% of amount)
        uint96 activationFee = _calculateActivationFee(amount);
        uint96 tabBalance = amount - activationFee;

        // --- Effects ---
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

        // --- Interactions ---
        // Pull full amount from agent, then send activation fee to fee wallet.
        // Tab balance stays in this contract.
        bool sent = usdc.transferFrom(agent, address(this), tabBalance);
        if (!sent) revert PayErrors.TransferFailed();

        sent = usdc.transferFrom(agent, feeWallet, activationFee);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.TabOpened(tabId, agent, provider, tabBalance, maxChargePerCall, activationFee);
    }

    /// @dev Core topUp logic. CEI: checks → effects → interactions (USDC transfer).
    ///      No activation fee on top-ups. Agent must be the tab's agent.
    function _topUp(address caller, bytes32 tabId, uint96 amount) internal {
        PayTypes.Tab storage t = _tabs[tabId];

        // --- Checks ---
        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (amount == 0) revert PayErrors.ZeroAmount();
        // Only the tab's agent (or relayer on their behalf) can top up
        if (caller != t.agent) revert PayErrors.Unauthorized(caller);

        // --- Effects ---
        t.amount += amount;

        // --- Interactions ---
        bool sent = usdc.transferFrom(caller, address(this), amount);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.TabToppedUp(tabId, amount, t.amount);
    }

    /// @dev Activation fee: max(MIN_ACTIVATION_FEE, amount / 100).
    ///      At MIN_TAB_AMOUNT ($5), fee = max($0.10, $0.05) = $0.10.
    ///      At $10+, fee = 1% of amount.
    function _calculateActivationFee(uint96 amount) internal pure returns (uint96) {
        uint96 percentFee = amount / 100;
        return percentFee > PayTypes.MIN_ACTIVATION_FEE ? percentFee : PayTypes.MIN_ACTIVATION_FEE;
    }
}

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
    // IPayTab — closeTab
    // =========================================================================

    /// @inheritdoc IPayTab
    /// @dev CEI: checks → effects (status + volume) → interactions (USDC transfers).
    ///      Distribution: provider gets totalCharged - fee, fee wallet gets fee, agent gets remaining.
    ///      If totalCharged == 0, no fee, full balance refunded to agent.
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
        uint96 remaining = t.amount;

        // Calculate fee on totalCharged (not on remaining balance)
        uint96 fee = 0;
        uint96 providerPayout = 0;
        if (totalCharged > 0) {
            uint96 rateBps = payFee.getFeeRate(provider);
            fee = uint96((uint256(totalCharged) * rateBps) / 10_000);
            providerPayout = totalCharged - fee;
        }

        // --- Effects ---
        t.status = PayTypes.TabStatus.Closed;
        t.amount = 0;

        // Record volume for provider (even if fee is dust/zero)
        if (totalCharged > 0) {
            payFee.recordTransaction(provider, totalCharged);
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
            chargeCount: 0
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

    /// @dev Activation fee: max(MIN_ACTIVATION_FEE, amount / 100).
    ///      At MIN_TAB_AMOUNT ($5), fee = max($0.10, $0.05) = $0.10.
    ///      At $10+, fee = 1% of amount.
    function _calculateActivationFee(uint96 amount) internal pure returns (uint96) {
        uint96 percentFee = amount / 100;
        return percentFee > PayTypes.MIN_ACTIVATION_FEE ? percentFee : PayTypes.MIN_ACTIVATION_FEE;
    }
}

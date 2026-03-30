// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPayTab} from "./interfaces/IPayTab.sol";
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
///        active → active (via chargeTab, topUpTab — future PRs)
///        active → closed (via closeTab — future PR)
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
    /// @param feeWallet_ Protocol fee wallet
    /// @param relayer_ Authorized relayer address
    constructor(address usdc_, address feeWallet_, address relayer_) {
        if (usdc_ == address(0)) revert PayErrors.ZeroAddress();
        if (feeWallet_ == address(0)) revert PayErrors.ZeroAddress();
        if (relayer_ == address(0)) revert PayErrors.ZeroAddress();

        usdc = IUSDC(usdc_);
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
            status: PayTypes.TabStatus.Active
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

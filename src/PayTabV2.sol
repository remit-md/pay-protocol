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

/// @title PayTabV2
/// @notice Pre-funded metered account with batch settlement. Agent locks USDC, provider charges per use.
/// @dev IMMUTABLE — no proxy, no admin key, no upgrade path. Holds USDC.
///
///      Identical to PayTab v1 with the addition of settleCharges() for batch settlement.
///      Deployed alongside v1. v1 is immutable, stays forever. New tabs open on v2.
///
///      State machine:
///        nonexistent -> active (via openTab)
///        active -> active (via chargeTab, settleCharges, topUpTab)
///        active -> closed (via closeTab)
///
///      Trust model change for settleCharges:
///        Server attests that no individual charge in the batch exceeded maxChargePerCall.
///        Contract checks the attestation value. Per-charge enforcement moves from real-time
///        on-chain to attested+auditable. Agent's total risk is still bounded by tab balance.
///        Fraud is provable via TabSettled event logs.
contract PayTabV2 is IPayTabV2, ReentrancyGuard {
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

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploy PayTabV2.
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
    // settleCharges — NEW in v2
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
    // IPayTab — openTab (identical to v1)
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
    // IPayTab — withdrawCharged
    // =========================================================================

    /// @inheritdoc IPayTab
    function withdrawCharged(bytes32 tabId) external nonReentrant {
        PayTypes.Tab storage t = _tabs[tabId];

        if (t.agent == address(0)) revert PayErrors.TabNotFound(tabId);
        if (t.status != PayTypes.TabStatus.Active) revert PayErrors.TabClosed(tabId);
        if (msg.sender != t.provider && msg.sender != relayer) {
            revert PayErrors.Unauthorized(msg.sender);
        }

        uint96 unwithdrawn = t.totalCharged - t.totalWithdrawn;
        if (unwithdrawn == 0) revert PayErrors.NothingToWithdraw(tabId);
        if (unwithdrawn < PayTypes.MIN_DIRECT_AMOUNT) {
            revert PayErrors.BelowMinimum(unwithdrawn, PayTypes.MIN_DIRECT_AMOUNT);
        }

        uint96 rateBps = payFee.getFeeRate(t.provider);
        uint96 fee = uint96((uint256(unwithdrawn) * rateBps) / 10_000);
        uint96 payout = unwithdrawn - fee;

        t.totalWithdrawn += unwithdrawn;
        payFee.recordTransaction(t.provider, unwithdrawn);

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

        uint96 unwithdrawn = totalCharged - totalWithdrawn;
        uint96 fee = 0;
        uint96 providerPayout = 0;
        if (unwithdrawn > 0) {
            uint96 rateBps = payFee.getFeeRate(provider);
            fee = uint96((uint256(unwithdrawn) * rateBps) / 10_000);
            providerPayout = unwithdrawn - fee;
        }

        t.status = PayTypes.TabStatus.Closed;
        t.amount = 0;

        if (unwithdrawn > 0) {
            payFee.recordTransaction(provider, unwithdrawn);
        }

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
    ///      At $10, fee = max($0.10, $0.10) = $0.10.
    ///      Above $10, fee = 1% of amount.
    function _calculateActivationFee(uint96 amount) internal pure returns (uint96) {
        uint96 percentFee = amount / 100;
        return percentFee > PayTypes.MIN_ACTIVATION_FEE ? percentFee : PayTypes.MIN_ACTIVATION_FEE;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPayDirect} from "./interfaces/IPayDirect.sol";
import {IPayFee} from "./interfaces/IPayFee.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {PayTypes} from "./libraries/PayTypes.sol";
import {PayErrors} from "./libraries/PayErrors.sol";
import {PayEvents} from "./libraries/PayEvents.sol";

/// @title PayDirect
/// @notice One-shot USDC transfer with fee deduction. Atomic — no state stored.
/// @dev IMMUTABLE — no proxy, no admin key, no upgrade path. Does not hold funds.
///
///      Flow:
///        1. Validate inputs (minimum, addresses)
///        2. Calculate fee via PayFee
///        3. Record volume via PayFee
///        4. Transfer USDC: (amount - fee) → provider, fee → feeWallet
///        5. Emit DirectPayment event
///
///      The agent sends the full amount. The provider receives amount minus fee.
///      Fee goes to the protocol fee wallet.
contract PayDirect is IPayDirect, ReentrancyGuard {
    // =========================================================================
    // Immutable state (set once in constructor, never changes)
    // =========================================================================

    /// @notice USDC token contract on Base.
    IUSDC public immutable usdc;

    /// @notice Fee calculator (UUPS proxy).
    IPayFee public immutable payFee;

    /// @notice Protocol fee wallet — receives all processing fees.
    address public immutable feeWallet;

    /// @notice Authorized relayer address (submits transactions on behalf of agents).
    address public immutable relayer;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Deploy PayDirect.
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
    // IPayDirect
    // =========================================================================

    /// @inheritdoc IPayDirect
    function payDirect(address to, uint96 amount, bytes32 memo) external nonReentrant {
        _executePayment(msg.sender, to, amount, memo);
    }

    /// @inheritdoc IPayDirect
    function payDirectFor(address agent, address to, uint96 amount, bytes32 memo)
        external
        nonReentrant
        onlyRelayer
    {
        if (agent == address(0)) revert PayErrors.ZeroAddress();
        _executePayment(agent, to, amount, memo);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Core payment logic. CEI pattern: checks → effects (fee recording) → interactions (transfers).
    function _executePayment(address from, address to, uint96 amount, bytes32 memo) internal {
        // --- Checks ---
        if (to == address(0)) revert PayErrors.ZeroAddress();
        if (from == to) revert PayErrors.SelfPayment(from);
        if (amount < PayTypes.MIN_DIRECT_AMOUNT) {
            revert PayErrors.BelowMinimum(amount, PayTypes.MIN_DIRECT_AMOUNT);
        }

        uint96 fee = payFee.calculateFee(to, amount);
        uint96 providerAmount = amount - fee;

        // --- Effects (external state update on PayFee) ---
        payFee.recordTransaction(to, amount);

        // --- Interactions (USDC transfers) ---
        bool sent = usdc.transferFrom(from, to, providerAmount);
        if (!sent) revert PayErrors.TransferFailed();

        sent = usdc.transferFrom(from, feeWallet, fee);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.DirectPayment(from, to, amount, fee, memo);
    }
}

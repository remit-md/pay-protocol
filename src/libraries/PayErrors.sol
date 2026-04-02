// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PayErrors
/// @notice Shared custom errors for all Pay contracts
library PayErrors {
    // Authorization
    error Unauthorized(address caller);
    error ZeroAddress();

    // Amounts
    error BelowMinimum(uint96 amount, uint96 minimum);
    error ZeroAmount();

    // Tab
    error TabNotFound(bytes32 tabId);
    error TabClosed(bytes32 tabId);
    error TabAlreadyExists(bytes32 tabId);
    error ChargeLimitExceeded(bytes32 tabId, uint96 amount, uint96 maxCharge);
    error InsufficientBalance(bytes32 tabId, uint96 amount, uint96 balance);
    error NothingToWithdraw(bytes32 tabId);
    error SelfPayment(address wallet);

    // Transfer
    error TransferFailed();

    // Fee
    error ZeroFee(uint96 amount);
}

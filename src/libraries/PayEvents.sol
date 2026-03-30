// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PayEvents
/// @notice Shared event definitions for all Pay contracts
library PayEvents {
    // === Direct Payment Events ===
    event DirectPayment(address indexed from, address indexed to, uint96 amount, uint96 fee, bytes32 memo);

    // === Tab Events ===
    event TabOpened(
        bytes32 indexed tabId,
        address indexed agent,
        address indexed provider,
        uint96 amount,
        uint96 maxChargePerCall,
        uint96 activationFee
    );

    event TabCharged(bytes32 indexed tabId, uint96 amount, uint96 balanceRemaining, uint256 chargeCount);

    event TabClosed(bytes32 indexed tabId, uint96 totalCharged, uint96 providerPayout, uint96 fee, uint96 agentRefund);

    event TabToppedUp(bytes32 indexed tabId, uint96 amount, uint96 newBalance);

    // === x402 Events ===
    event X402Settled(address indexed from, address indexed to, uint96 amount, uint96 fee, bytes32 indexed nonce);

    // === Fee Events ===
    event CallerAuthorized(address indexed caller);
    event CallerRevoked(address indexed caller);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}

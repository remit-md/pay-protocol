// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPayRouter
/// @notice Entry point for x402 settlement and relayer management.
interface IPayRouter {
    /// @notice Settle an x402 direct payment via EIP-3009 receiveWithAuthorization.
    /// @dev Only callable by authorized relayers. Pulls USDC from agent, splits to provider + feeWallet.
    /// @param from Agent address (signed the EIP-3009 authorization)
    /// @param to Provider address (receives payment minus fee)
    /// @param amount Total payment amount in USDC (6 decimals)
    /// @param validAfter EIP-3009 validity start timestamp
    /// @param validBefore EIP-3009 validity end timestamp
    /// @param nonce EIP-3009 nonce (unique per authorization)
    /// @param v ECDSA signature component
    /// @param r ECDSA signature component
    /// @param s ECDSA signature component
    function settleX402(
        address from,
        address to,
        uint96 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Authorize a relayer address to call settleX402.
    /// @param relayerAddr The address to authorize.
    function authorizeRelayer(address relayerAddr) external;

    /// @notice Revoke a relayer's authorization.
    /// @param relayerAddr The address to deauthorize.
    function revokeRelayer(address relayerAddr) external;

    /// @notice Check if an address is an authorized relayer.
    /// @param relayerAddr The address to check.
    /// @return True if the address is an authorized relayer.
    function isAuthorizedRelayer(address relayerAddr) external view returns (bool);
}

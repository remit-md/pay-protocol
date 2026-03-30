// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPayDirect
/// @notice One-shot USDC transfer with fee deduction. Provider pays 1% (0.75% above $50k/month).
/// @dev IMMUTABLE — no proxy, no admin key, no upgrade path.
interface IPayDirect {
    /// @notice Send a direct USDC payment. Caller is the payer.
    /// @param to Provider address (receives amount minus fee)
    /// @param amount Total payment amount (USDC, 6 decimals). Minimum $1.00 (1_000_000).
    /// @param memo Arbitrary reference (e.g. task ID). Emitted in event, not stored.
    function payDirect(address to, uint96 amount, bytes32 memo) external;

    /// @notice Relayer-submitted direct payment on behalf of an agent.
    /// @param agent The payer (must have approved USDC to this contract via permit).
    /// @param to Provider address (receives amount minus fee)
    /// @param amount Total payment amount (USDC, 6 decimals). Minimum $1.00 (1_000_000).
    /// @param memo Arbitrary reference. Emitted in event, not stored.
    /// @dev Only callable by the authorized relayer.
    function payDirectFor(address agent, address to, uint96 amount, bytes32 memo) external;
}

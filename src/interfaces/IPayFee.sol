// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPayFee
/// @notice Fee calculation and per-provider volume tracking
/// @dev UUPS upgradeable. Provider pays processing fee (1%, or 0.75% above $50k/month).
interface IPayFee {
    /// @notice Calculate fee for a transaction amount given the provider's current volume
    /// @param provider The provider receiving the payment
    /// @param amount Transaction amount (USDC, 6 decimals)
    /// @return fee The fee amount (USDC, 6 decimals)
    function calculateFee(address provider, uint96 amount) external view returns (uint96 fee);

    /// @notice Get current monthly volume for a provider
    /// @param provider The provider address
    /// @return volume Monthly volume in USDC (6 decimals)
    function getMonthlyVolume(address provider) external view returns (uint256 volume);

    /// @notice Record a transaction for provider volume tracking
    /// @param provider The provider receiving the payment
    /// @param amount Transaction amount (USDC, 6 decimals)
    /// @dev Only callable by authorized contracts (PayDirect, PayTab, PayRouter).
    function recordTransaction(address provider, uint96 amount) external;

    /// @notice Get fee rate for a provider (in basis points)
    /// @param provider The provider address
    /// @return rateBps Fee rate (100 = 1%, 75 = 0.75%)
    function getFeeRate(address provider) external view returns (uint96 rateBps);
}

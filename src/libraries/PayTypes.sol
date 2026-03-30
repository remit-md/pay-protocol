// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PayTypes
/// @notice Shared type definitions for all Pay contracts
library PayTypes {
    /// @notice Tab status
    enum TabStatus {
        Active, // 0: open, charges allowed
        Closed // 1: closed, funds distributed
    }

    /// @notice Tab struct (packed for gas efficiency)
    /// @dev address (20 bytes) + uint96 (12 bytes) = 32 bytes = 1 slot
    struct Tab {
        address agent;
        uint96 amount; // current remaining balance
        address provider;
        uint96 totalCharged; // cumulative charges
        uint96 maxChargePerCall; // agent-set per-charge limit
        uint96 activationFee; // fee paid at open
        TabStatus status;
    }

    /// @notice Fee tiers — cliff model (not marginal)
    /// @dev Provider pays processing fee. Volume tracked per-provider, calendar-month reset.
    uint96 constant FEE_RATE_BPS = 100; // 1% (below $50k/month provider volume)
    uint96 constant FEE_RATE_PREFERRED_BPS = 75; // 0.75% (above $50k/month provider volume)
    uint96 constant FEE_THRESHOLD = 50_000e6; // $50,000 monthly volume cliff (USDC, 6 decimals)

    /// @notice Minimum amounts (contract-enforced)
    uint96 constant MIN_DIRECT_AMOUNT = 1_000_000; // $1.00 in USDC (6 decimals)
    uint96 constant MIN_TAB_AMOUNT = 5_000_000; // $5.00 in USDC (6 decimals)

    /// @notice Activation fee floor
    uint96 constant MIN_ACTIVATION_FEE = 100_000; // $0.10 in USDC (6 decimals)
}

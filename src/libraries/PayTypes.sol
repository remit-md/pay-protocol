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
    /// @dev Slot 0: agent (20) + amount (12) = 32
    ///      Slot 1: provider (20) + totalCharged (12) = 32
    ///      Slot 2: maxChargePerCall (12) + activationFee (12) + status (1) = 25
    ///      Slot 3: chargeCount (32)
    ///      Slot 4: totalWithdrawn (12) + 20 free
    struct Tab {
        address agent;
        uint96 amount; // current remaining balance
        address provider;
        uint96 totalCharged; // cumulative charges
        uint96 maxChargePerCall; // agent-set per-charge limit
        uint96 activationFee; // fee paid at open
        TabStatus status;
        uint256 chargeCount; // number of charges applied
        uint96 totalWithdrawn; // cumulative amount provider has withdrawn
    }

    /// @notice Fee tiers — cliff model (not marginal)
    /// @dev Provider pays processing fee. Volume tracked per-provider, calendar-month reset.
    uint96 constant FEE_RATE_BPS = 100; // 1% (below $50k/month provider volume)
    uint96 constant FEE_RATE_PREFERRED_BPS = 75; // 0.75% (above $50k/month provider volume)
    uint96 constant FEE_THRESHOLD = 50_000e6; // $50,000 monthly volume cliff (USDC, 6 decimals)

    /// @notice Minimum amounts (contract-enforced)
    uint96 constant MIN_DIRECT_AMOUNT = 1_000_000; // $1.00 in USDC (6 decimals)
    uint96 constant MIN_TAB_AMOUNT = 5_000_000; // $5.00 in USDC (6 decimals)

    /// @notice Minimum withdrawal amount (scheduled rectification)
    uint96 constant MIN_WITHDRAW_AMOUNT = 100_000; // $0.10 in USDC (6 decimals)

    /// @notice Activation fee floor
    uint96 constant MIN_ACTIVATION_FEE = 100_000; // $0.10 in USDC (6 decimals)

    /// @notice Per-charge minimum fee (server-enforced, not contract-enforced)
    /// @dev max($0.002, 1%) per charge. Below $0.20/call the floor kicks in.
    uint96 constant MIN_CHARGE_FEE = 2_000; // $0.002 in USDC (6 decimals)

    /// @notice V5 tab struct — packed into 4 storage slots (down from 5 + mapping in V4).
    /// @dev Slot 0: agent (20) + amount (12) = 32
    ///      Slot 1: provider (20) + totalCharged (12) = 32
    ///      Slot 2: maxChargePerCall (12) + activationFee (12) + status (1) + chargeCount (4) = 29
    ///      Slot 3: totalWithdrawn (12) + chargeCountAtLastWithdraw (4) = 16
    struct TabV5 {
        address agent;
        uint96 amount;
        address provider;
        uint96 totalCharged;
        uint96 maxChargePerCall;
        uint96 activationFee;
        TabStatus status;
        uint32 chargeCount;
        uint96 totalWithdrawn;
        uint32 chargeCountAtLastWithdraw;
    }
}

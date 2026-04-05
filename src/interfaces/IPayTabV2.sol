// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPayTab} from "./IPayTab.sol";

/// @title IPayTabV2
/// @notice PayTab v2 adds batch settlement via settleCharges.
///         Retains all v1 functions (openTab, chargeTab, closeTab, etc.) for backwards compat.
/// @dev IMMUTABLE — no proxy, no admin key, no upgrade path. Holds funds.
///      Deployed alongside v1 (v1 stays forever, immutable).
interface IPayTabV2 is IPayTab {
    /// @notice Settle accumulated charges for a tab in a single batch.
    /// @param tabId The tab to charge.
    /// @param totalAmount Sum of all individual charges in this batch (USDC, 6 decimals).
    /// @param chargeCount Number of individual charges represented.
    /// @param maxSingleCharge Relayer attestation: largest individual charge in batch.
    ///        Contract checks maxSingleCharge <= maxChargePerCall. Fraud is provable
    ///        via event logs (settlement event records the attestation).
    /// @dev Only callable by authorized relayer.
    ///      Checks: tab active, totalAmount <= balance, maxSingleCharge <= maxChargePerCall.
    ///      Effects: balance -= totalAmount, totalCharged += totalAmount, chargeCount += chargeCount.
    ///      No USDC transfer — just SSTORE. USDC moves at close/withdraw.
    function settleCharges(bytes32 tabId, uint96 totalAmount, uint32 chargeCount, uint96 maxSingleCharge) external;
}

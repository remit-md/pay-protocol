// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PayTypes} from "../libraries/PayTypes.sol";

/// @title IPayTab
/// @notice Pre-funded metered account. Agent locks USDC, provider charges per use.
/// @dev IMMUTABLE — no proxy, no admin key, no upgrade path. Holds funds.
///
///      Complete interface: openTab, openTabFor, chargeTab, topUpTab, topUpTabFor, closeTab, getTab.
interface IPayTab {
    /// @notice Open a tab. Caller is the agent. Locks USDC and deducts activation fee.
    /// @param tabId Unique tab identifier (caller-generated, e.g. keccak256 of nonce).
    /// @param provider Provider address (receives charged amounts at close).
    /// @param amount Total USDC to lock (6 decimals). Minimum $5.00 (5_000_000).
    /// @param maxChargePerCall Maximum amount the provider can charge per call (6 decimals).
    function openTab(bytes32 tabId, address provider, uint96 amount, uint96 maxChargePerCall) external;

    /// @notice Relayer-submitted tab open on behalf of an agent.
    /// @param agent The payer (must have approved USDC to this contract via permit).
    /// @param tabId Unique tab identifier.
    /// @param provider Provider address.
    /// @param amount Total USDC to lock (6 decimals). Minimum $5.00 (5_000_000).
    /// @param maxChargePerCall Maximum amount the provider can charge per call (6 decimals).
    /// @dev Only callable by the authorized relayer.
    function openTabFor(address agent, bytes32 tabId, address provider, uint96 amount, uint96 maxChargePerCall) external;

    /// @notice Charge a tab. Decrements balance, increments totalCharged. No USDC transfer.
    /// @param tabId The tab to charge.
    /// @param amount Charge amount (USDC, 6 decimals). Must be <= maxChargePerCall and <= remaining balance.
    /// @dev Only callable by the authorized relayer (server pre-validates, then submits on-chain).
    function chargeTab(bytes32 tabId, uint96 amount) external;

    /// @notice Top up an open tab. Agent adds more USDC. No additional activation fee.
    /// @param tabId The tab to top up.
    /// @param amount Additional USDC to add (6 decimals).
    function topUpTab(bytes32 tabId, uint96 amount) external;

    /// @notice Relayer-submitted top-up on behalf of an agent.
    /// @param agent The payer (must have approved USDC to this contract via permit).
    /// @param tabId The tab to top up.
    /// @param amount Additional USDC to add (6 decimals).
    /// @dev Only callable by the authorized relayer.
    function topUpTabFor(address agent, bytes32 tabId, uint96 amount) external;

    /// @notice Provider withdraws all unwithdrawn charged funds minus fee. Tab stays open.
    /// @param tabId The tab to withdraw from.
    /// @dev Callable by provider or relayer. Withdraws (totalCharged - totalWithdrawn).
    function withdrawCharged(bytes32 tabId) external;

    /// @notice Close a tab. Distributes funds: provider gets unwithdrawn charges minus fee, fee wallet gets fee, agent gets remaining balance.
    /// @param tabId The tab to close.
    /// @dev Callable by agent, provider, or relayer. Unilateral — neither party can block the other.
    function closeTab(bytes32 tabId) external;

    /// @notice Get tab details.
    /// @param tabId The tab identifier.
    /// @return tab The tab struct.
    function getTab(bytes32 tabId) external view returns (PayTypes.Tab memory tab);
}

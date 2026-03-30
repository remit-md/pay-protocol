// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPayRouter} from "./interfaces/IPayRouter.sol";
import {IPayFee} from "./interfaces/IPayFee.sol";
import {IUSDC} from "./interfaces/IUSDC.sol";
import {PayTypes} from "./libraries/PayTypes.sol";
import {PayErrors} from "./libraries/PayErrors.sol";
import {PayEvents} from "./libraries/PayEvents.sol";

/// @title PayRouter
/// @notice Entry point for x402 settlement and relayer management.
/// @dev UPGRADEABLE via UUPS proxy. Does NOT hold funds — receives USDC via
///      EIP-3009 receiveWithAuthorization, then immediately distributes.
///
///      State machine:
///        uninitialized → initialized (via initialize)
///
///      Safety:
///        - only authorized relayers can call settleX402
///        - only owner can authorize/revoke relayers and upgrade
///        - x402 nonce replay prevented by USDC (EIP-3009)
///        - fee must never be zero
///        - minimum $1 on x402 settlements (same as direct)
///
///      Settlement flow:
///        1. Relayer calls settleX402 with EIP-3009 signature from agent
///        2. Router pulls USDC from agent via receiveWithAuthorization
///        3. Router calculates fee via PayFee
///        4. Router records volume via PayFee
///        5. Router transfers (amount - fee) to provider, fee to feeWallet
///        6. Emits X402Settled event
contract PayRouter is IPayRouter, UUPSUpgradeable, ReentrancyGuard {
    // =========================================================================
    // Storage (proxy-safe layout — slots 0+ used by proxy context)
    // =========================================================================

    /// @dev Guard to prevent double-initialization.
    bool private _initialized;

    /// @dev Contract owner (can upgrade and manage relayers).
    address private _owner;

    /// @dev USDC token contract on Base.
    IUSDC public usdc;

    /// @dev Fee calculator (UUPS proxy).
    IPayFee public payFee;

    /// @dev Protocol fee wallet — receives all processing fees.
    address public feeWallet;

    /// @dev Authorized relayer addresses.
    mapping(address => bool) public authorizedRelayers;

    // =========================================================================
    // Constructor — disables direct initialization of implementation contract
    // =========================================================================

    constructor() {
        _initialized = true;
    }

    // =========================================================================
    // Initializer — called once through the proxy during deployment
    // =========================================================================

    /// @notice Initialize the router (proxy deployment only).
    /// @param owner_ The initial owner address (protocol admin).
    /// @param usdc_ USDC token address on Base.
    /// @param payFee_ PayFee calculator (proxy address).
    /// @param feeWallet_ Protocol fee wallet.
    function initialize(address owner_, address usdc_, address payFee_, address feeWallet_) external {
        if (_initialized) revert PayErrors.Unauthorized(msg.sender);
        if (owner_ == address(0)) revert PayErrors.ZeroAddress();
        if (usdc_ == address(0)) revert PayErrors.ZeroAddress();
        if (payFee_ == address(0)) revert PayErrors.ZeroAddress();
        if (feeWallet_ == address(0)) revert PayErrors.ZeroAddress();

        _initialized = true;
        _owner = owner_;
        usdc = IUSDC(usdc_);
        payFee = IPayFee(payFee_);
        feeWallet = feeWallet_;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != _owner) revert PayErrors.Unauthorized(msg.sender);
        _;
    }

    modifier onlyAuthorizedRelayer() {
        if (!authorizedRelayers[msg.sender]) revert PayErrors.Unauthorized(msg.sender);
        _;
    }

    // =========================================================================
    // IPayRouter — settleX402
    // =========================================================================

    /// @inheritdoc IPayRouter
    /// @dev CEI: checks → effects (fee recording) → interactions (USDC transfers).
    ///      Uses EIP-3009 receiveWithAuthorization to pull USDC from agent.
    ///      The router receives the full amount, then distributes: provider gets
    ///      (amount - fee), fee wallet gets fee.
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
    ) external nonReentrant onlyAuthorizedRelayer {
        // --- Checks ---
        if (from == address(0)) revert PayErrors.ZeroAddress();
        if (to == address(0)) revert PayErrors.ZeroAddress();
        if (from == to) revert PayErrors.SelfPayment(from);
        if (amount < PayTypes.MIN_DIRECT_AMOUNT) {
            revert PayErrors.BelowMinimum(amount, PayTypes.MIN_DIRECT_AMOUNT);
        }

        uint96 fee = payFee.calculateFee(to, amount);
        uint96 providerAmount = amount - fee;

        // --- Effects (external state update on PayFee) ---
        payFee.recordTransaction(to, amount);

        // --- Interactions ---
        // Pull USDC from agent via EIP-3009. to == address(this) enforced by USDC.
        usdc.receiveWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, v, r, s);

        // Distribute: provider gets net, fee wallet gets fee.
        bool sent = usdc.transfer(to, providerAmount);
        if (!sent) revert PayErrors.TransferFailed();

        sent = usdc.transfer(feeWallet, fee);
        if (!sent) revert PayErrors.TransferFailed();

        emit PayEvents.X402Settled(from, to, amount, fee, nonce);
    }

    // =========================================================================
    // IPayRouter — relayer management
    // =========================================================================

    /// @inheritdoc IPayRouter
    function authorizeRelayer(address relayerAddr) external onlyOwner {
        if (relayerAddr == address(0)) revert PayErrors.ZeroAddress();
        authorizedRelayers[relayerAddr] = true;
        emit PayEvents.CallerAuthorized(relayerAddr);
    }

    /// @inheritdoc IPayRouter
    function revokeRelayer(address relayerAddr) external onlyOwner {
        if (relayerAddr == address(0)) revert PayErrors.ZeroAddress();
        authorizedRelayers[relayerAddr] = false;
        emit PayEvents.CallerRevoked(relayerAddr);
    }

    /// @inheritdoc IPayRouter
    function isAuthorizedRelayer(address relayerAddr) external view returns (bool) {
        return authorizedRelayers[relayerAddr];
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Transfer ownership to a new address.
    /// @param newOwner The new owner address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert PayErrors.ZeroAddress();
        address previous = _owner;
        _owner = newOwner;
        emit PayEvents.OwnershipTransferred(previous, newOwner);
    }

    /// @notice Get the current owner.
    function owner() external view returns (address) {
        return _owner;
    }

    // =========================================================================
    // UUPSUpgradeable
    // =========================================================================

    /// @dev Only the owner can authorize an upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Storage gap (reserve 50 slots for future upgrades)
    // =========================================================================

    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;
}

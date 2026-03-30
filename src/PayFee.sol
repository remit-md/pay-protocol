// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IPayFee} from "./interfaces/IPayFee.sol";
import {PayTypes} from "./libraries/PayTypes.sol";
import {PayErrors} from "./libraries/PayErrors.sol";
import {PayEvents} from "./libraries/PayEvents.sol";

/// @title PayFee
/// @notice Fee calculation with cliff-based tiering and per-provider calendar month volume tracking.
/// @dev UPGRADEABLE via UUPS proxy. This is one of two upgradeable contracts (with PayRouter).
///      Fund-holding contracts (PayTab, PayDirect) are immutable.
///
///      Fee tiers (in basis points, 10000 = 100%):
///        Standard  : 100 bps (1.00%) — provider monthly volume < $50,000 USDC
///        Preferred : 75 bps  (0.75%) — provider monthly volume >= $50,000 USDC
///
///      Cliff: once a provider's cumulative received volume crosses $50,000 in a calendar month,
///      ALL subsequent transactions that month are charged at 75 bps. No marginal split.
///
///      Volume resets on the 1st of every calendar month (UTC).
///
///      Ownership is managed via an initialize() + onlyOwner pattern (no OZ Upgradeable
///      dependency) so we only need openzeppelin/contracts (non-upgradeable package).
contract PayFee is IPayFee, UUPSUpgradeable {
    // =========================================================================
    // Storage (proxy-safe layout — slots 0+ are used by proxy context)
    // =========================================================================

    /// @dev Guard to prevent double-initialization.
    bool private _initialized;

    /// @dev Contract owner (can upgrade and authorize callers).
    address private _owner;

    /// @dev Monthly volume per provider (raw, may be from a stale month — use _getCurrentVolume).
    mapping(address => uint256) public monthlyVolume;

    /// @dev Calendar month key at which this provider's volume was last set.
    ///      monthKey = year * 12 + month (e.g. 24315 for March 2026).
    mapping(address => uint256) public lastResetMonth;

    /// @dev Contracts authorized to call recordTransaction (PayDirect, PayTab, PayRouter).
    mapping(address => bool) public authorizedCallers;

    // =========================================================================
    // Constructor — disables direct initialization of implementation contract
    // =========================================================================

    constructor() {
        _initialized = true;
    }

    // =========================================================================
    // Initializer — called once through the proxy during deployment
    // =========================================================================

    /// @notice Initialize the fee calculator (proxy deployment only).
    /// @param owner_ The initial owner address (protocol admin).
    function initialize(address owner_) external {
        if (_initialized) revert PayErrors.Unauthorized(msg.sender);
        if (owner_ == address(0)) revert PayErrors.ZeroAddress();
        _initialized = true;
        _owner = owner_;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != _owner) revert PayErrors.Unauthorized(msg.sender);
        _;
    }

    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender]) revert PayErrors.Unauthorized(msg.sender);
        _;
    }

    // =========================================================================
    // IPayFee
    // =========================================================================

    /// @inheritdoc IPayFee
    /// @dev Cliff-based: once monthly volume >= $50k, preferred rate applies to the ENTIRE
    ///      transaction. No marginal split — the transaction that pushes you past $50k is
    ///      still charged at standard rate; the NEXT transaction gets preferred.
    function calculateFee(address provider, uint96 amount) external view override returns (uint96 fee) {
        if (amount == 0) revert PayErrors.ZeroAmount();
        if (_getCurrentVolume(provider) >= PayTypes.FEE_THRESHOLD) {
            fee = uint96((uint256(amount) * PayTypes.FEE_RATE_PREFERRED_BPS) / 10_000);
        } else {
            fee = uint96((uint256(amount) * PayTypes.FEE_RATE_BPS) / 10_000);
        }
        if (fee == 0) revert PayErrors.ZeroFee(amount);
    }

    /// @inheritdoc IPayFee
    function getMonthlyVolume(address provider) external view override returns (uint256 volume) {
        return _getCurrentVolume(provider);
    }

    /// @inheritdoc IPayFee
    /// @dev Only callable by authorized contracts (PayDirect, PayTab, PayRouter).
    function recordTransaction(address provider, uint96 amount) external override onlyAuthorized {
        _resetIfNewMonth(provider);
        monthlyVolume[provider] += amount;
    }

    /// @inheritdoc IPayFee
    function getFeeRate(address provider) external view override returns (uint96 rateBps) {
        return _getCurrentVolume(provider) >= PayTypes.FEE_THRESHOLD
            ? PayTypes.FEE_RATE_PREFERRED_BPS
            : PayTypes.FEE_RATE_BPS;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Authorize a contract to call recordTransaction.
    /// @param caller The contract address to authorize (e.g. PayDirect).
    function authorizeCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert PayErrors.ZeroAddress();
        authorizedCallers[caller] = true;
        emit PayEvents.CallerAuthorized(caller);
    }

    /// @notice Revoke a contract's authorization to call recordTransaction.
    /// @param caller The contract address to deauthorize.
    function revokeCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert PayErrors.ZeroAddress();
        authorizedCallers[caller] = false;
        emit PayEvents.CallerRevoked(caller);
    }

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
    // Internal
    // =========================================================================

    /// @dev Returns the provider's effective volume for the current calendar month.
    ///      Returns 0 if the provider hasn't received payments in the current month.
    function _getCurrentVolume(address provider) internal view returns (uint256) {
        if (lastResetMonth[provider] < _getMonthKey(block.timestamp)) {
            return 0;
        }
        return monthlyVolume[provider];
    }

    /// @dev Resets volume to zero if we've entered a new calendar month.
    function _resetIfNewMonth(address provider) internal {
        uint256 currentMonth = _getMonthKey(block.timestamp);
        if (lastResetMonth[provider] < currentMonth) {
            monthlyVolume[provider] = 0;
            lastResetMonth[provider] = currentMonth;
        }
    }

    /// @dev Returns a unique key for the calendar month containing `timestamp`.
    ///      Uses the Hinnant civil date algorithm (same as C++ std::chrono).
    ///      Result = year * 12 + month (e.g. 24315 for March 2026). Gas: ~200.
    function _getMonthKey(uint256 timestamp) internal pure returns (uint256) {
        uint256 z = timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = yoe + era * 400;
        if (m <= 2) y += 1;
        return y * 12 + m;
    }

    // =========================================================================
    // Storage gap (reserve 50 slots for future upgrades)
    // =========================================================================

    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;
}

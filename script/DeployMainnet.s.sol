// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayDirect} from "../src/PayDirect.sol";
import {PayTab} from "../src/PayTab.sol";
import {PayRouter} from "../src/PayRouter.sol";

/// @title DeployMainnet
/// @notice Mainnet deployment script for Base. Uses real USDC.
///         Reads GNOSIS_SAFE and FEE_WALLET from environment.
///         Deployer deploys and configures, then transfers proxy ownership to Safe.
///         Fund-holding contracts (PayDirect, PayTab) have immutable feeWallet set to FEE_WALLET.
///
/// @dev Prerequisites:
///      - DEPLOYER_PRIVATE_KEY: key with ~0.05 ETH on Base mainnet for gas
///      - GNOSIS_SAFE:          Gnosis Safe address (proxy owner after deployment)
///      - FEE_WALLET:           Fee recipient address (defaults to deployer if not set)
///      - BASE_MAINNET_RPC_URL: Base mainnet RPC URL
///      - BASESCAN_API_KEY:     for contract verification
///
///      Run with:
///        forge script script/DeployMainnet.s.sol \
///          --broadcast \
///          --rpc-url $BASE_MAINNET_RPC_URL \
///          --private-key $DEPLOYER_PRIVATE_KEY \
///          --verify \
///          --etherscan-api-key $BASESCAN_API_KEY
contract DeployMainnet is Script {
    /// @dev USDC on Base mainnet.
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal _payFeeProxy;
    address internal _payDirect;
    address internal _payTab;
    address internal _payRouterProxy;

    function run() external {
        address deployer = msg.sender;

        // Admin: defaults to deployer when GNOSIS_SAFE is not set (dry-runs).
        // For production: set GNOSIS_SAFE to the multisig address.
        address admin = vm.envOr("GNOSIS_SAFE", deployer);
        address feeWallet = vm.envOr("FEE_WALLET", deployer);

        console2.log("=== Pay Protocol - Mainnet Deployment (Base) ===");
        console2.log("Deployer:  ", deployer);
        console2.log("Admin/Safe:", admin);
        console2.log("Fee Wallet:", feeWallet);
        console2.log("USDC:      ", USDC);
        console2.log("");

        vm.startBroadcast();

        // Deploy with deployer as initial owner (needed for configuration).
        // Fund-holding contracts get feeWallet as immutable param.
        _deployPayFee(deployer);
        _deployPayDirect(deployer, feeWallet);
        _deployPayTab(deployer, feeWallet);
        _deployPayRouter(deployer, feeWallet);
        _authorizeCallers();
        _authorizeRelayer(deployer);

        // Transfer proxy ownership to Safe (if set).
        if (admin != deployer) {
            _transferOwnership(admin);
        }

        vm.stopBroadcast();

        _logSummary(deployer, admin, feeWallet);
    }

    /// @dev Deploy PayFee behind UUPS proxy. Deployer is owner.
    function _deployPayFee(address owner) internal {
        PayFee impl = new PayFee();
        bytes memory initData = abi.encodeCall(impl.initialize, (owner));
        _payFeeProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("PayFee (proxy):    ", _payFeeProxy);
    }

    /// @dev Deploy PayDirect (immutable). feeWallet and deployer (as relayer) are immutable.
    function _deployPayDirect(address deployer, address feeWallet) internal {
        _payDirect = address(new PayDirect(USDC, _payFeeProxy, feeWallet, deployer));
        console2.log("PayDirect:         ", _payDirect);
    }

    /// @dev Deploy PayTab (immutable). feeWallet and deployer (as relayer) are immutable.
    function _deployPayTab(address deployer, address feeWallet) internal {
        _payTab = address(new PayTab(USDC, _payFeeProxy, feeWallet, deployer));
        console2.log("PayTab:            ", _payTab);
    }

    /// @dev Deploy PayRouter behind UUPS proxy. Deployer is initial owner, feeWallet receives fees.
    function _deployPayRouter(address deployer, address feeWallet) internal {
        PayRouter impl = new PayRouter();
        bytes memory initData = abi.encodeCall(impl.initialize, (deployer, USDC, _payFeeProxy, feeWallet));
        _payRouterProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("PayRouter (proxy): ", _payRouterProxy);
    }

    /// @dev Authorize PayDirect, PayTab, and PayRouter to call recordTransaction on PayFee.
    function _authorizeCallers() internal {
        PayFee feeProxy = PayFee(_payFeeProxy);
        feeProxy.authorizeCaller(_payDirect);
        feeProxy.authorizeCaller(_payTab);
        feeProxy.authorizeCaller(_payRouterProxy);
        console2.log("PayFee: authorized PayDirect, PayTab, PayRouter");
    }

    /// @dev Authorize the deployer as a relayer on PayRouter (for x402 settlements).
    function _authorizeRelayer(address deployer) internal {
        PayRouter(_payRouterProxy).authorizeRelayer(deployer);
        console2.log("PayRouter: authorized relayer", deployer);
    }

    /// @dev Transfer ownership of UUPS proxies (PayFee, PayRouter) to the Safe.
    function _transferOwnership(address admin) internal {
        PayFee(_payFeeProxy).transferOwnership(admin);
        console2.log("PayFee: ownership transferred to", admin);

        PayRouter(_payRouterProxy).transferOwnership(admin);
        console2.log("PayRouter: ownership transferred to", admin);
    }

    function _logSummary(address deployer, address admin, address feeWallet) internal view {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Network:           Base Mainnet (chainId 8453)");
        console2.log("Deployer:          ", deployer);
        console2.log("Admin/Safe:        ", admin);
        console2.log("Fee Wallet:        ", feeWallet);
        console2.log("");
        console2.log("--- Contracts ---");
        console2.log("USDC (native):     ", USDC);
        console2.log("PayFee (proxy):    ", _payFeeProxy);
        console2.log("PayDirect:         ", _payDirect);
        console2.log("PayTab:            ", _payTab);
        console2.log("PayRouter (proxy): ", _payRouterProxy);
        console2.log("");
        console2.log("--- Server .env snippet ---");
        console2.log("CHAIN_ID=8453");
        console2.log("RPC_URL=<base_mainnet_rpc_url>");
        console2.log("SERVER_SIGNING_KEY=<deployer_private_key>");
        console2.log("USDC_ADDRESS=", USDC);
        console2.log("PAY_FEE_ADDRESS=", _payFeeProxy);
        console2.log("PAY_DIRECT_ADDRESS=", _payDirect);
        console2.log("PAY_TAB_ADDRESS=", _payTab);
        console2.log("PAY_ROUTER_ADDRESS=", _payRouterProxy);
        console2.log("FEE_WALLET=", feeWallet);
    }
}

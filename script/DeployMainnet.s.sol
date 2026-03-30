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
///         The deployer address serves as: owner, fee wallet, and relayer.
///
/// @dev Run with:
///      forge script script/DeployMainnet.s.sol \
///        --broadcast \
///        --rpc-url $BASE_MAINNET_RPC_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY \
///        --verify \
///        --etherscan-api-key $BASESCAN_API_KEY
contract DeployMainnet is Script {
    /// @dev USDC on Base mainnet.
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal _payFeeProxy;
    address internal _payDirect;
    address internal _payTab;
    address internal _payRouterProxy;

    function run() external {
        address deployer = msg.sender;

        console2.log("=== Pay Protocol - Mainnet Deployment (Base) ===");
        console2.log("Deployer / Owner / FeeWallet / Relayer:", deployer);
        console2.log("USDC:", USDC);
        console2.log("");

        vm.startBroadcast();

        _deployPayFee(deployer);
        _deployPayDirect(deployer);
        _deployPayTab(deployer);
        _deployPayRouter(deployer);
        _authorizeCallers();
        _authorizeRelayer(deployer);

        vm.stopBroadcast();

        _logSummary(deployer);
    }

    /// @dev Deploy PayFee behind UUPS proxy. Deployer is owner.
    function _deployPayFee(address owner) internal {
        PayFee impl = new PayFee();
        bytes memory initData = abi.encodeCall(impl.initialize, (owner));
        _payFeeProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("PayFee (proxy):    ", _payFeeProxy);
    }

    /// @dev Deploy PayDirect (immutable). Deployer is fee wallet and relayer.
    function _deployPayDirect(address deployer) internal {
        _payDirect = address(new PayDirect(USDC, _payFeeProxy, deployer, deployer));
        console2.log("PayDirect:         ", _payDirect);
    }

    /// @dev Deploy PayTab (immutable). Deployer is fee wallet and relayer.
    function _deployPayTab(address deployer) internal {
        _payTab = address(new PayTab(USDC, _payFeeProxy, deployer, deployer));
        console2.log("PayTab:            ", _payTab);
    }

    /// @dev Deploy PayRouter behind UUPS proxy. Deployer is owner and fee wallet.
    function _deployPayRouter(address deployer) internal {
        PayRouter impl = new PayRouter();
        bytes memory initData = abi.encodeCall(impl.initialize, (deployer, USDC, _payFeeProxy, deployer));
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

    function _logSummary(address deployer) internal view {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Network:           Base Mainnet (chainId 8453)");
        console2.log("Deployer:          ", deployer);
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
        console2.log("RELAYER_PRIVATE_KEY=<deployer_private_key>");
        console2.log("USDC_ADDRESS=", USDC);
        console2.log("PAY_FEE_ADDRESS=", _payFeeProxy);
        console2.log("PAY_DIRECT_ADDRESS=", _payDirect);
        console2.log("PAY_TAB_ADDRESS=", _payTab);
        console2.log("PAY_ROUTER_ADDRESS=", _payRouterProxy);
        console2.log("FEE_WALLET=", deployer);
    }
}

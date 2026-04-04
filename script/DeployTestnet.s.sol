// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayDirect} from "../src/PayDirect.sol";
import {PayTab} from "../src/PayTab.sol";
import {PayTabV2} from "../src/PayTabV2.sol";
import {PayRouter} from "../src/PayRouter.sol";
import {MockUSDC} from "../src/test/MockUSDC.sol";

/// @title DeployTestnet
/// @notice Testnet deployment script for Base Sepolia. Deploys MockUSDC + full protocol.
///         The deployer address serves as: owner, fee wallet, and relayer.
///
/// @dev Run with:
///      forge script script/DeployTestnet.s.sol \
///        --broadcast \
///        --rpc-url $BASE_SEPOLIA_RPC_URL \
///        --private-key $DEPLOYER_PRIVATE_KEY \
///        --verify \
///        --etherscan-api-key $BASESCAN_API_KEY
contract DeployTestnet is Script {
    address internal _usdc;
    address internal _payFeeProxy;
    address internal _payDirect;
    address internal _payTab;
    address internal _payTabV2;
    address internal _payRouterProxy;

    function run() external {
        address deployer = msg.sender;

        console2.log("=== Pay Protocol - Testnet Deployment (Base Sepolia) ===");
        console2.log("Deployer / Owner / FeeWallet / Relayer:", deployer);
        console2.log("");

        vm.startBroadcast();

        _deployMockUSDC(deployer);
        _deployPayFee(deployer);
        _deployPayDirect(deployer);
        _deployPayTab(deployer);
        _deployPayTabV2(deployer);
        _deployPayRouter(deployer);
        _authorizeCallers();
        _authorizeRelayer(deployer);

        vm.stopBroadcast();

        _logSummary(deployer);
    }

    /// @dev Deploy MockUSDC and mint $1M to deployer for testing.
    function _deployMockUSDC(address deployer) internal {
        MockUSDC usdc = new MockUSDC();
        _usdc = address(usdc);
        usdc.mint(deployer, 1_000_000e6);
        console2.log("MockUSDC:          ", _usdc);
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
        _payDirect = address(new PayDirect(_usdc, _payFeeProxy, deployer, deployer));
        console2.log("PayDirect:         ", _payDirect);
    }

    /// @dev Deploy PayTab v1 (immutable). Deployer is fee wallet and relayer.
    function _deployPayTab(address deployer) internal {
        _payTab = address(new PayTab(_usdc, _payFeeProxy, deployer, deployer));
        console2.log("PayTab (v1):       ", _payTab);
    }

    /// @dev Deploy PayTab v2 (immutable, batch settlement). Deployer is fee wallet and relayer.
    function _deployPayTabV2(address deployer) internal {
        _payTabV2 = address(new PayTabV2(_usdc, _payFeeProxy, deployer, deployer));
        console2.log("PayTabV2:          ", _payTabV2);
    }

    /// @dev Deploy PayRouter behind UUPS proxy. Deployer is owner and fee wallet.
    function _deployPayRouter(address deployer) internal {
        PayRouter impl = new PayRouter();
        bytes memory initData = abi.encodeCall(impl.initialize, (deployer, _usdc, _payFeeProxy, deployer));
        _payRouterProxy = address(new ERC1967Proxy(address(impl), initData));
        console2.log("PayRouter (proxy): ", _payRouterProxy);
    }

    /// @dev Authorize PayDirect, PayTab, and PayRouter to call recordTransaction on PayFee.
    function _authorizeCallers() internal {
        PayFee feeProxy = PayFee(_payFeeProxy);
        feeProxy.authorizeCaller(_payDirect);
        feeProxy.authorizeCaller(_payTab);
        feeProxy.authorizeCaller(_payTabV2);
        feeProxy.authorizeCaller(_payRouterProxy);
        console2.log("PayFee: authorized PayDirect, PayTab, PayTabV2, PayRouter");
    }

    /// @dev Authorize the deployer as a relayer on PayRouter (for x402 settlements).
    function _authorizeRelayer(address deployer) internal {
        PayRouter(_payRouterProxy).authorizeRelayer(deployer);
        console2.log("PayRouter: authorized relayer", deployer);
    }

    function _logSummary(address deployer) internal view {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Network:           Base Sepolia (chainId 84532)");
        console2.log("Deployer:          ", deployer);
        console2.log("");
        console2.log("--- Contracts ---");
        console2.log("MockUSDC:          ", _usdc);
        console2.log("PayFee (proxy):    ", _payFeeProxy);
        console2.log("PayDirect:         ", _payDirect);
        console2.log("PayTab (v1):       ", _payTab);
        console2.log("PayTabV2:          ", _payTabV2);
        console2.log("PayRouter (proxy): ", _payRouterProxy);
        console2.log("");
        console2.log("--- Server .env snippet ---");
        console2.log("CHAIN_ID=84532");
        console2.log("RPC_URL=<base_sepolia_rpc_url>");
        console2.log("RELAYER_PRIVATE_KEY=<deployer_private_key>");
        console2.log("USDC_ADDRESS=", _usdc);
        console2.log("PAY_FEE_ADDRESS=", _payFeeProxy);
        console2.log("PAY_DIRECT_ADDRESS=", _payDirect);
        console2.log("PAY_TAB_ADDRESS=", _payTab);
        console2.log("PAY_TAB_V2_ADDRESS=", _payTabV2);
        console2.log("PAY_ROUTER_ADDRESS=", _payRouterProxy);
        console2.log("FEE_WALLET=", deployer);
    }
}

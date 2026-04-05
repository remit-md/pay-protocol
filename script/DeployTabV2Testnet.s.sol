// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayTabV2} from "../src/PayTabV2.sol";

/// @title DeployTabV2Testnet
/// @notice Deploy ONLY PayTabV2 on Base Sepolia against existing infrastructure.
///         Reads existing contract addresses from environment.
///
/// @dev Prerequisites:
///      - DEPLOYER_PRIVATE_KEY: same deployer as original deploy
///      - ALCHEMY_BASE_SEPOLIA_URL: Base Sepolia RPC
///      - PAY_FEE_ADDRESS: existing PayFee proxy address
///      - USDC_ADDRESS: existing MockUSDC address
///      - FEE_WALLET: existing fee wallet (defaults to deployer)
///
///      Run with:
///        forge script script/DeployTabV2Testnet.s.sol \
///          --broadcast \
///          --rpc-url $ALCHEMY_BASE_SEPOLIA_URL \
///          --private-key $DEPLOYER_PRIVATE_KEY \
///          --verify \
///          --verifier blockscout \
///          --verifier-url https://base-sepolia.blockscout.com/api
contract DeployTabV2Testnet is Script {
    function run() external {
        address deployer = msg.sender;

        // Read existing addresses from env
        address usdc = vm.envAddress("USDC_ADDRESS");
        address payFeeProxy = vm.envAddress("PAY_FEE_ADDRESS");
        address feeWallet = vm.envOr("FEE_WALLET", deployer);

        console2.log("=== PayTabV2 Deployment (Base Sepolia) ===");
        console2.log("Deployer:       ", deployer);
        console2.log("USDC:           ", usdc);
        console2.log("PayFee (proxy): ", payFeeProxy);
        console2.log("Fee Wallet:     ", feeWallet);
        console2.log("");

        vm.startBroadcast();

        // Deploy PayTabV2 (immutable)
        PayTabV2 tabV2 = new PayTabV2(usdc, payFeeProxy, feeWallet, deployer);
        console2.log("PayTabV2:       ", address(tabV2));

        // Authorize PayTabV2 to call recordTransaction on PayFee
        PayFee(payFeeProxy).authorizeCaller(address(tabV2));
        console2.log("PayFee: authorized PayTabV2");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Done ===");
        console2.log("Add to server .env:");
        console2.log("TAB_V2_ADDRESS=", address(tabV2));
    }
}

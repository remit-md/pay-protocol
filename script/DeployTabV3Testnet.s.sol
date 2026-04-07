// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayTabV3} from "../src/PayTabV3.sol";

/// @title DeployTabV3Testnet
/// @notice Deploy ONLY PayTabV3 on Base Sepolia against existing infrastructure.
///         Reads existing contract addresses from environment.
///
/// @dev Prerequisites:
///      - DEPLOYER_PRIVATE_KEY: same deployer as original deploy
///      - ALCHEMY_BASE_SEPOLIA_URL: Base Sepolia RPC
///      - PAY_FEE_ADDRESS: existing PayFee proxy address
///      - USDC_ADDRESS: existing MockUSDC address
///      - FEE_WALLET: existing fee wallet (defaults to deployer)
///
///      Changes from V2:
///        - withdrawCharged: onlyRelayer (was provider OR relayer)
///        - MIN_WITHDRAW_AMOUNT: $0.10 (was MIN_DIRECT_AMOUNT $1.00)
contract DeployTabV3Testnet is Script {
    function run() external {
        address deployer = msg.sender;

        // Read existing addresses from env
        address usdc = vm.envAddress("USDC_ADDRESS");
        address payFeeProxy = vm.envAddress("PAY_FEE_ADDRESS");
        address feeWallet = vm.envOr("FEE_WALLET", deployer);

        console2.log("=== PayTabV3 Deployment (Base Sepolia) ===");
        console2.log("Deployer:       ", deployer);
        console2.log("USDC:           ", usdc);
        console2.log("PayFee (proxy): ", payFeeProxy);
        console2.log("Fee Wallet:     ", feeWallet);
        console2.log("");

        vm.startBroadcast();

        // Deploy PayTabV3 (immutable)
        PayTabV3 tabV3 = new PayTabV3(usdc, payFeeProxy, feeWallet, deployer);
        console2.log("PayTabV3:       ", address(tabV3));

        // Authorize PayTabV3 to call recordTransaction on PayFee
        PayFee(payFeeProxy).authorizeCaller(address(tabV3));
        console2.log("PayFee: authorized PayTabV3");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Done ===");
        console2.log("Add to server .env:");
        console2.log("TAB_V3_ADDRESS=", address(tabV3));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {PayFee} from "../src/PayFee.sol";
import {PayTabV5} from "../src/PayTabV5.sol";

/// @title DeployTabV5Testnet
/// @notice Deploy ONLY PayTabV5 on Base Sepolia against existing infrastructure.
///         Reads existing contract addresses from environment.
///
/// @dev Prerequisites:
///      - DEPLOYER_PRIVATE_KEY: same deployer as original deploy
///      - ALCHEMY_BASE_SEPOLIA_URL: Base Sepolia RPC
///      - PAY_FEE_ADDRESS: existing PayFee proxy address
///      - USDC_ADDRESS: existing MockUSDC address
///      - FEE_WALLET: existing fee wallet (defaults to deployer)
///
///      Changes from V4:
///        - Fee accumulation: activation + processing fees stored in contract,
///          swept via sweepFees() to feeWallet.
///        - ReentrancyGuardTransient: EIP-1153 TSTORE/TLOAD.
///        - Packed struct: 4 slots (chargeCount uint32, chargeCountAtLastWithdraw merged).
contract DeployTabV5Testnet is Script {
    function run() external {
        address deployer = msg.sender;

        // Read existing addresses from env
        address usdc = vm.envAddress("USDC_ADDRESS");
        address payFeeProxy = vm.envAddress("PAY_FEE_ADDRESS");
        address feeWallet = vm.envOr("FEE_WALLET", deployer);

        console2.log("=== PayTabV5 Deployment (Base Sepolia) ===");
        console2.log("Deployer:       ", deployer);
        console2.log("USDC:           ", usdc);
        console2.log("PayFee (proxy): ", payFeeProxy);
        console2.log("Fee Wallet:     ", feeWallet);
        console2.log("");

        vm.startBroadcast();

        // Deploy PayTabV5 (immutable)
        PayTabV5 tabV5 = new PayTabV5(usdc, payFeeProxy, feeWallet, deployer);
        console2.log("PayTabV5:       ", address(tabV5));

        // Authorize PayTabV5 to call recordTransaction on PayFee
        PayFee(payFeeProxy).authorizeCaller(address(tabV5));
        console2.log("PayFee: authorized PayTabV5");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Done ===");
        console2.log("Update server .env:");
        console2.log("TAB_V2_ADDRESS=", address(tabV5));
    }
}

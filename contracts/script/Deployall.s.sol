// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SafeguardCircuitBreaker} from "../src/SafeguardCircuitBreaker.sol";
import {USDSToken} from "../src/USDSToken.sol";
import {ReserveManager} from "../src/ReserveManager.sol";

/**
 * @title DeployAll
 * @notice One-click deployment for the entire hackathon demo
 * 
 * USAGE:
 * ======
 * forge script script/DeployAll.s.sol:DeployAll \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --broadcast \
 *   --verify \
 *   -vvvv
 * 
 * DEPLOYED CONTRACTS:
 * ===================
 * 1. SafeguardCircuitBreaker → receives health reports from Chainlink
 * 2. USDSToken               → the stablecoin users hold
 * 3. ReserveManager          → holds USDC reserves, mints/burns USDS
 * 
 * AFTER DEPLOYMENT:
 * =================
 * Copy the 3 contract addresses into workflow/config.staging.json
 */
contract DeployAll is Script {
    // Sepolia USDC address (mock USDC for testnet)
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    
    // Chainlink KeystoneForwarder on Sepolia (check docs.chain.link/cre for latest)
    //NOT: This address changes between testnet versions – verify before deploying
    address constant FORWARDER_SEPOLIA = 0x15fC6ae953E024d975e77382eEeC56A9101f9F88; // UPDATE THIS from docs

    function run() external {
        // Load deployer private key from .env
        uint256 deployerKey = vm.envUint("CRE_ETH_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log(unicode"═══════════════════════════════════════════════════════════");
        console.log("HACKATHON DEMO - DEPLOYING ALL CONTRACTS");
        console.log(unicode"═══════════════════════════════════════════════════════════");
        console.log("Deployer:", deployer);
        console.log("USDC (reserves):", USDC_SEPOLIA);
        console.log("Forwarder:", FORWARDER_SEPOLIA);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 1: Deploy Circuit Breaker
        // ═══════════════════════════════════════════════════════════════════════
        console.log("1/3 Deploying SafeguardCircuitBreaker...");
        SafeguardCircuitBreaker breaker = new SafeguardCircuitBreaker(
            FORWARDER_SEPOLIA, // forwarder
            deployer           // owner
        );
        console.log("   Circuit Breaker:", address(breaker));
        console.log("");

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 2: Deploy USDS Token (with placeholder, will be updated later)
        // ═══════════════════════════════════════════════════════════════════════
        console.log("2/3 Deploying USDSToken...");
        
        // Deploy with deployer as temporary reserve manager
        // We'll transfer this role to the real ReserveManager in step 4
        USDSToken usds = new USDSToken(
            address(breaker), // circuitBreaker
            deployer,         // temporary reserveManager (will update after step 3)
            deployer          // owner
        );
        console.log("   USDS Token:", address(usds));
        console.log("");

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 3: Deploy Reserve Manager
        // ═══════════════════════════════════════════════════════════════════════
        console.log("3/3 Deploying ReserveManager...");
        ReserveManager manager = new ReserveManager(
            USDC_SEPOLIA,  // reserveToken
            address(usds), // usdsToken
            deployer       // owner
        );
        console.log("   Reserve Manager:", address(manager));
        console.log("");

        // ═══════════════════════════════════════════════════════════════════════
        // STEP 4: Wire everything together
        // ═══════════════════════════════════════════════════════════════════════
        console.log("Configuring contracts...");
        
        // Update USDS to use the real ReserveManager
        usds.setReserveManager(address(manager));
        console.log("   Set ReserveManager in USDSToken");
        console.log("");

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════════════════
        // SUMMARY
        // ═══════════════════════════════════════════════════════════════════════
        console.log(unicode"═══════════════════════════════════════════════════════════");
        console.log("DEPLOYMENT COMPLETE");
        console.log(unicode"═══════════════════════════════════════════════════════════");
        console.log("");
        console.log(" COPY THESE ADDRESSES TO workflow/config.staging.json:");
        console.log(unicode"───────────────────────────────────────────────────────────");
        console.log('"usdcAddress": "%s",', USDC_SEPOLIA);
        console.log('"tokenAddress": "%s",', address(usds));
        console.log('"reserveManagerAddress": "%s",', address(manager));
        console.log('"circuitBreakerAddress": "%s",', address(breaker));
        console.log(unicode"═══════════════════════════════════════════════════════════");
    }
}

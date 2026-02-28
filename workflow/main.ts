import {
  cre,
  CronCapability,
  consensusMedianAggregation,
  encodeCallMsg,
  bytesToHex,
  hexToBase64,
  getNetwork,
  LAST_FINALIZED_BLOCK_NUMBER,
  Runner,
  handler,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  type Address,
  encodeFunctionData,
  decodeFunctionResult,
  encodeAbiParameters,
  parseAbiParameters,
  parseAbi,
  zeroAddress,
} from "viem";
import { z } from "zod";

// ═══════════════════════════════════════════════════════════════════════════
// HACKATHON DEMO CONFIG
// ═══════════════════════════════════════════════════════════════════════════
/**
 * CONFIG EXPLANATION:
 * ===================
 * This workflow reads TWO smart contracts on Ethereum:
 * 
 * 1. ReserveManager.getReserves() → How much USDC is in the vault
 * 2. USDSToken.totalSupply()      → How many USDS tokens exist
 * 
 * Then calculates: ratio = (reserves / supply) * 10000
 * 
 * If ratio < 10050 (100.5%) → CRITICAL HALT triggered
 */

const configSchema = z.object({
  //** Cron: "0 */1 * * * *" = every 60 seconds *//
  schedule: z.string(),
  
  /** ReserveManager contract address (holds USDC reserves) */
  reserveManagerAddress: z.string(),
  
  /** USDSToken contract address (the stablecoin) */
  tokenAddress: z.string(),
  
  /** USDC contract address (Sepolia: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) */
  usdcAddress: z.string(),
  
  /** SafeguardCircuitBreaker contract address */
  circuitBreakerAddress: z.string(),
  
  /** Chain name */
  chainSelectorName: z.string(),
  
  /** Gas limit for onchain write */
  gasLimit: z.string().default("500000"),
  
  /** Reserve ratio thresholds in basis points */
  tier1ThresholdBps: z.number().default(10150), // 101.5%
  tier2ThresholdBps: z.number().default(10100), // 101.0%
  tier3ThresholdBps: z.number().default(10050), // 100.5%
});

type Config = z.infer<typeof configSchema>;

// ═══════════════════════════════════════════════════════════════════════════
// ABIs
// ═══════════════════════════════════════════════════════════════════════════

const erc20Abi = parseAbi([
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
]);

const reserveManagerAbi = parseAbi([
  "function getReserves() view returns (uint256)",
]);

// ═══════════════════════════════════════════════════════════════════════════
// TIER CLASSIFICATION
// ═══════════════════════════════════════════════════════════════════════════

const TIER = {
  HEALTHY:       0n,
  MINOR_DEFICIT: 1n,
  WARNING:       2n,
  CRITICAL:      3n,
} as const;

type TierValue = (typeof TIER)[keyof typeof TIER];

// ═══════════════════════════════════════════════════════════════════════════
// STEP 1: READ ON-CHAIN RESERVES (USDC balance of ReserveManager)
// ═══════════════════════════════════════════════════════════════════════════
/**
 * HACKATHON KEY POINT:
 * ====================
 * No "bank API" needed! We read reserves directly from Ethereum.
 * 
 * This calls: USDC.balanceOf(reserveManagerAddress)
 * Returns: Amount of USDC held by the reserve vault (6 decimals)
 * 
 * Example: If ReserveManager holds 1,000,000 USDC → returns 1000000e6
 */
const readOnchainReserves = (
  runtime:   Runtime<Config>,
  evmClient: InstanceType<typeof cre.capabilities.EVMClient>
): bigint => {
  const usdcAddress = runtime.config.usdcAddress as Address;
  const reserveManagerAddress = runtime.config.reserveManagerAddress as Address;

  // Encode the balanceOf(reserveManagerAddress) call
  const callData = encodeFunctionData({
    abi:  erc20Abi,
    functionName: "balanceOf",
    args: [reserveManagerAddress],
  });

  // Call USDC contract on Ethereum
  const result = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to:   usdcAddress,
        data: callData,
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER, // Only read finalized blocks
    })
    .result();

  // Decode the uint256 response
  const reserves = decodeFunctionResult({
    abi:          erc20Abi,
    functionName: "balanceOf",
    data:         bytesToHex(result.data),
  }) as bigint;

  // Convert USDC (6 decimals) to 18 decimals for ratio calculation
  // 1000000e6 USDC → 1000000e18 for math
  return reserves * 1_000_000_000_000n; // multiply by 1e12
};

// ═══════════════════════════════════════════════════════════════════════════
// STEP 2: READ ON-CHAIN SUPPLY (USDS.totalSupply())
// ═══════════════════════════════════════════════════════════════════════════
/**
 * HACKATHON KEY POINT:
 * ====================
 * This reads how many USDS tokens exist.
 * 
 * Example: If users minted 1,000,000 USDS → returns 1000000e18
 */
const readOnchainSupply = (
  runtime:   Runtime<Config>,
  evmClient: InstanceType<typeof cre.capabilities.EVMClient>
): bigint => {
  const tokenAddress = runtime.config.tokenAddress as Address;

  const callData = encodeFunctionData({
    abi:          erc20Abi,
    functionName: "totalSupply",
  });

  const result = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to:   tokenAddress,
        data: callData,
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
    })
    .result();

  const supply = decodeFunctionResult({
    abi:          erc20Abi,
    functionName: "totalSupply",
    data:         bytesToHex(result.data),
  }) as bigint;

  return supply;
};

// ═══════════════════════════════════════════════════════════════════════════
// STEP 3: CLASSIFY RATIO INTO TIER
// ═══════════════════════════════════════════════════════════════════════════
/**
 * HACKATHON DEMO - TIER EXAMPLES:
 * ================================
 * Reserves: 1,050,000 USDC, Supply: 1,000,000 USDS
 *   → Ratio: (1.05M / 1M) * 10000 = 10500 bps = 105%
 *   → Tier: HEALTHY ✅
 * 
 * Reserves: 1,010,000 USDC, Supply: 1,000,000 USDS
 *   → Ratio: 10100 bps = 101%
 *   → Tier: MINOR_DEFICIT ⚠️ (warning, but still operational)
 * 
 * Reserves: 1,004,000 USDC, Supply: 1,000,000 USDS
 *   → Ratio: 10040 bps = 100.4%
 *   → Tier: CRITICAL 🚨 (protocol HALTS immediately)
 */
const classifyRatio = (
  ratioBps: bigint,
  config:   Config
): { tier: TierValue; label: string } => {
  if (ratioBps >= BigInt(config.tier1ThresholdBps)) {
    return { tier: TIER.HEALTHY,       label: "HEALTHY" };
  }
  if (ratioBps >= BigInt(config.tier2ThresholdBps)) {
    return { tier: TIER.MINOR_DEFICIT, label: "TIER_1_MINOR_DEFICIT" };
  }
  if (ratioBps >= BigInt(config.tier3ThresholdBps)) {
    return { tier: TIER.WARNING,       label: "TIER_2_WARNING" };
  }
  return   { tier: TIER.CRITICAL,      label: "TIER_3_CRITICAL_HALT" };
};

// ═══════════════════════════════════════════════════════════════════════════
// STEP 4: SUBMIT SIGNED REPORT TO BLOCKCHAIN
// ═══════════════════════════════════════════════════════════════════════════
/**
 * HACKATHON KEY POINT:
 * ====================
 * This is where Chainlink's security comes in:
 * 
 * 1. All 10 Chainlink nodes independently calculated the ratio
 * 2. They all sign the report with their private keys
 * 3. One node submits the transaction with 7+ signatures attached
 * 4. KeystoneForwarder verifies the signatures
 * 5. Only if valid → forwards to SafeguardCircuitBreaker
 * 6. Circuit breaker updates state → halts protocol if CRITICAL
 * 
 * Security: A single hacked node CANNOT halt the protocol alone.
 */
const submitOnchainReport = (
  runtime:   Runtime<Config>,
  evmClient: InstanceType<typeof cre.capabilities.EVMClient>,
  ratioBps:  bigint,
  tier:      TierValue
): string => {
  const triggerHalt = tier === TIER.CRITICAL;

  // ABI-encode the report: (uint256 ratio, uint8 tier, bool halt)
  const reportData = encodeAbiParameters(
    parseAbiParameters("uint256 reserveRatioBps, uint8 tier, bool triggerHalt"),
    [ratioBps, Number(tier), triggerHalt]
  );

  // Get DON signatures (7+ nodes must sign for consensus)
  const signedReport = runtime
    .report({
      encodedPayload: hexToBase64(reportData),
      encoderName:    "evm",
      signingAlgo:    "ecdsa",
      hashingAlgo:    "keccak256",
    })
    .result();

  // Submit to Ethereum (KeystoneForwarder → SafeguardCircuitBreaker)
  const writeResult = evmClient
    .writeReport(runtime, {
      receiver:  runtime.config.circuitBreakerAddress,
      report:    signedReport,
      gasConfig: { gasLimit: runtime.config.gasLimit },
    })
    .result();

  if (!writeResult.txHash || writeResult.txHash.length === 0) {
    throw new Error("[Safeguard] writeReport returned empty txHash");
  }

  return bytesToHex(writeResult.txHash);
};

// ═══════════════════════════════════════════════════════════════════════════
// MAIN HEALTH-CHECK LOOP (RUNS EVERY 60 SECONDS)
// ═══════════════════════════════════════════════════════════════════════════
/**
 * HACKATHON DEMO FLOW:
 * ====================
 * This function executes every minute automatically:
 * 
 * 1. Read USDC reserves from blockchain
 * 2. Read USDS supply from blockchain
 * 3. Calculate ratio = (reserves / supply) * 10000
 * 4. If ratio < 100.5% → trigger CRITICAL halt
 * 5. Submit signed report to circuit breaker
 * 6. Circuit breaker updates state
 * 7. USDSToken.mint() checks state → reverts if halted
 * 
 * RESULT: Protocol automatically freezes before bank run! 🛡️
 */
const onHealthCheck = (runtime: Runtime<Config>): string => {
  runtime.log("═══════════════════════════════════════════════════════════");
  runtime.log("[SAFEGUARD] Health-check started");
  runtime.log("═══════════════════════════════════════════════════════════");

  // ── Initialize EVM client ──────────────────────────────────────────────────
  const network = getNetwork({
    chainFamily:       "evm",
    chainSelectorName: runtime.config.chainSelectorName,
    isTestnet:         runtime.config.chainSelectorName.includes("testnet"),
  });

  if (!network) {
    throw new Error(`Unknown chain: ${runtime.config.chainSelectorName}`);
  }

  const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector);

  // ── STEP 1: Read USDC reserves (on-chain, trustless) ───────────────────────
  runtime.log("[SAFEGUARD] Step 1: Reading USDC reserves from blockchain...");
  const reserves = readOnchainReserves(runtime, evmClient);
  runtime.log(`[SAFEGUARD]   ✓ Reserves: ${reserves.toString()} wei (${Number(reserves) / 1e18} USDC)`);

  // ── STEP 2: Read USDS supply (on-chain, trustless) ─────────────────────────
  runtime.log("[SAFEGUARD] Step 2: Reading USDS total supply...");
  const supply = readOnchainSupply(runtime, evmClient);
  runtime.log(`[SAFEGUARD]   ✓ Supply: ${supply.toString()} wei (${Number(supply) / 1e18} USDS)`);

  // ── STEP 3: Guard against division by zero ─────────────────────────────────
  if (supply === 0n) {
    runtime.log("[SAFEGUARD]   ⚠ Supply is zero – skipping this cycle");
    return "SKIP: zero supply";
  }

  // ── STEP 4: Calculate reserve ratio ────────────────────────────────────────
  const ratioBps = (reserves * 10_000n) / supply;
  const ratioPercent = Number(ratioBps) / 100;
  runtime.log(`[SAFEGUARD] Step 3: Reserve Ratio = ${ratioBps} bps (${ratioPercent}%)`);

  // ── STEP 5: Classify into tier ─────────────────────────────────────────────
  const { tier, label } = classifyRatio(ratioBps, runtime.config);
  runtime.log(`[SAFEGUARD] Step 4: Risk Tier = ${label}`);

  // ── STEP 6: Submit report to blockchain ────────────────────────────────────
  runtime.log("[SAFEGUARD] Step 5: Submitting signed report to circuit breaker...");
  const txHash = submitOnchainReport(runtime, evmClient, ratioBps, tier);
  runtime.log(`[SAFEGUARD]   ✓ Transaction: ${txHash}`);

  // ── Summary ────────────────────────────────────────────────────────────────
  const summary = `${label} | ${ratioPercent}% | tx:${txHash.slice(0, 10)}...`;
  runtime.log("═══════════════════════════════════════════════════════════");
  runtime.log(`[SAFEGUARD] ✅ Health-check complete: ${summary}`);
  runtime.log("═══════════════════════════════════════════════════════════");
  
  return summary;
};

// ═══════════════════════════════════════════════════════════════════════════
// WORKFLOW INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════

const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  return [handler(cron.trigger({ schedule: config.schedule }), onHealthCheck)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
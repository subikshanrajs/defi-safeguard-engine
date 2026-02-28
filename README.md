# 🏆 RWA Stablecoin with Autonomous Chainlink Safeguard

**Hackathon Project**: An institutional-grade stablecoin with an autonomous circuit breaker that prevents bank runs.

---

## 🎯 **What This Is**

A complete implementation of a **Real-World Asset (RWA) backed stablecoin** similar to USDC/USDT, with a **Chainlink Runtime Environment** workflow that:

- ✅ Monitors USDC reserves vs USDS token supply **every 60 seconds**
- ✅ Automatically **halts minting/redemptions** if reserves drop below 100.5% backing
- ✅ Prevents bank runs **without human intervention**
- ✅ Byzantine Fault Tolerant (10 Chainlink nodes reach consensus before acting)

---

## 📁 **Project Structure**

```
defi-safeguard/
├── contracts/              # Solidity smart contracts (Foundry)
│   ├── src/
│   │   ├── USDSToken.sol              # The stablecoin users hold
│   │   ├── ReserveManager.sol         # Holds USDC, mints/burns USDS
│   │   ├── SafeguardCircuitBreaker.sol # Receives Chainlink health reports
│   │   └── IReceiver.sol              # CRE consumer interface
│   └── script/
│       └── DeployAll.s.sol            # One-click deployment
│
├── workflow/               # Chainlink Runtime Environment workflow
│   ├── main.ts                        # Health-check logic (runs on DON)
│   ├── config.staging.json            # Contract addresses
│   ├── package.json
│   └── tsconfig.json
│
├── DEMO_GUIDE.md          # Step-by-step presentation guide
├── .env.example           # Environment variables template
└── README.md              # This file
```

---

## 🚀 **Quick Start**

### **Prerequisites**
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Bun](https://bun.sh) v1.1+
- [CRE CLI](https://docs.chain.link/cre): `npm install -g @chainlink/cre-cli`
- Sepolia ETH (get from [faucet.chainlink.com](https://faucet.chainlink.com))
- Sepolia USDC (get from [faucet.circle.com](https://faucet.circle.com))

### **Step 1: Clone & Install**

```bash
cd hackathon-demo

# Install Solidity dependencies
cd contracts
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts

# Install workflow dependencies
cd ../workflow
bun install
```

### **Step 2: Configure**

```bash
cd ..
cp .env.example .env
# Edit .env with your Sepolia private key and RPC URL
```

### **Step 3: Deploy Contracts**

```bash
cd contracts
source ../.env

# Deploy all 3 contracts to Sepolia
forge script script/DeployAll.s.sol:DeployAll \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

Copy the printed addresses into `workflow/config.staging.json`.

### **Step 4: Deploy Workflow to Chainlink**

```bash
cd ../workflow

# Authenticate with Chainlink
cre login

# Test simulation
cre workflow simulate safeguard-workflow \
  --target staging-settings \
  --broadcast \
  --trigger-index 0

# Deploy to production
cre workflow deploy safeguard-workflow --target staging-settings
```

**Result:** Chainlink will now monitor your protocol **every 60 seconds** automatically.

---

## 🎬 **Live Demo Flow**

See [DEMO_GUIDE.md](./DEMO_GUIDE.md) for the complete hackathon presentation script.

**30-second version:**

1. **Healthy State**: User deposits 1000 USDC → receives 1000 USDS → Chainlink confirms 100% backing ✅
2. **Reserve Drain**: Owner simulates hack by withdrawing 500 USDC → reserves drop to 50% 🚨
3. **Auto-Halt**: Next Chainlink check (60 sec) → detects critical ratio → circuit breaker HALTS protocol
4. **Bank Run Prevented**: Users trying to mint/redeem → transactions REVERT → protocol frozen 🛡️

---

## 🏗️ **Technical Architecture**

### **Smart Contracts (Ethereum Sepolia)**

```
USDSToken
├─ Checks: circuitBreaker.isProtocolPaused()
├─ If true → mint()/burn() revert
└─ Controlled by ReserveManager

ReserveManager
├─ Holds USDC reserves
├─ deposit() → user sends USDC, receives USDS
├─ redeem() → user burns USDS, receives USDC
└─ emergencyWithdraw() → (demo only) simulate reserve drain

SafeguardCircuitBreaker
├─ Receives health reports from Chainlink
├─ onReport() → decodes (ratio, tier, halt)
├─ If tier == CRITICAL → isProtocolPaused = true
└─ Owned by deployer (can manually resume)
```

### **Chainlink Workflow (Decentralized Oracle Network)**

```
onHealthCheck() [runs every 60 seconds]
├─ Step 1: Read USDC.balanceOf(ReserveManager)
├─ Step 2: Read USDSToken.totalSupply()
├─ Step 3: Calculate ratio = (reserves / supply) * 10000
├─ Step 4: Classify tier:
│   ├─ ratio >= 101.5% → HEALTHY
│   ├─ 101.0% - 101.5% → MINOR_DEFICIT
│   ├─ 100.5% - 101.0% → WARNING
│   └─ ratio < 100.5%  → CRITICAL (halt!)
├─ Step 5: ABI-encode report
├─ Step 6: Get DON signatures (7+ of 10 nodes)
└─ Step 7: Submit to KeystoneForwarder → CircuitBreaker
```

---

## 🔑 **Key Features**

### **1. Fully On-Chain & Trustless**
- No centralized APIs (bank API was just an example in the spec)
- Reserves are USDC held in a smart contract
- Anyone can verify the reserves on Etherscan

### **2. Byzantine Fault Tolerant**
- 10 independent Chainlink nodes monitor reserves
- Consensus required (7+ nodes must agree)
- Single compromised node cannot halt the protocol

### **3. Autonomous**
- No human intervention required
- Executes every 60 seconds automatically
- Faster response than manual governance votes

### **4. Production-Ready**
- Multi-tier response system (not just on/off)
- Replay protection (same report can't be submitted twice)
- Stale report guard (old reports rejected)
- Owner can manually resume after verification

---

## 🧪 **Testing**

### **Unit Tests (Foundry)**

```bash
cd contracts
forge test -vvv
```

### **Simulation (CRE)**

```bash
cd workflow

# Dry run (no transactions)
cre workflow simulate safeguard-workflow --target staging-settings

# Live test on Sepolia
cre workflow simulate safeguard-workflow \
  --target staging-settings \
  --broadcast \
  --trigger-index 0
```

---

## 🌟 **Use Cases**

### **1. Stablecoins (USDC/USDT Competitors)**
- Monitor bank reserves vs token supply
- Auto-halt if reserves drop (prevent Terra/Luna scenario)

### **2. Tokenized Treasury Bills**
- Monitor custodian-held T-bills vs token supply
- Ensure 1:1 backing at all times

### **3. Wrapped Bitcoin (WBTC)**
- Monitor BTC wallet balance vs wrapped token supply
- Halt if BTC is drained from custody

### **4. Tokenized Real Estate**
- Monitor property valuations vs token supply
- Halt if property value drops below backing ratio

---

## 📊 **Metrics**

- **Contracts**: 3 (Circuit Breaker, Token, Reserve Manager)
- **Lines of Code**: ~1,200 (Solidity + TypeScript)
- **Health Check Frequency**: Every 60 seconds
- **Response Time**: < 2 minutes (60s check + 30s tx confirmation)
- **Security**: 10-node BFT consensus

---

## 📚 **Further Reading**

- [Chainlink Runtime Environment Docs](https://docs.chain.link/cre)
- [Proof of Reserve Overview](https://chain.link/education-hub/proof-of-reserves)
- [Terra/Luna Collapse Analysis](https://www.coindesk.com/learn/the-fall-of-terra-a-timeline-of-the-meteoric-rise-and-crash-of-ust-and-luna/)

---

## 📝 **License**

MIT License - Built for [Hackathon Name] 2026

---

## 🙏 **Acknowledgments**

- Chainlink Labs for the Runtime Environment
- OpenZeppelin for secure contract libraries
- Foundry for blazing-fast Solidity tooling

---


**Built with ❤️ for a safer DeFi future.**

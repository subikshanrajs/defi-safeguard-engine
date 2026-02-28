# 🛡️ Autonomous DeFi Protocol Safeguard Engine

**An autonomous circuit breaker for RWA stablecoins powered by Chainlink Runtime Environment**



## 🎯 Overview

Real-time monitoring and autonomous circuit breaker system that prevents bank runs in asset-backed DeFi protocols by detecting under-collateralization within 60 seconds.

**Problem:** Traditional stablecoins rely on periodic attestations. If reserves drop between reports, users might not discover issues until it's too late (see: Terra/Luna $40B collapse).

**Solution:** Chainlink oracles monitor reserves vs token supply every 60 seconds and automatically halt operations when ratios fall below safe thresholds.

---

## 🎬 Demo Video

**[▶️ Watch 3-Minute Demo](YOUR_VIDEO_LINK_HERE)**

Video shows:
- Initial deposit (20 USDC → 20 USDS)
- Emergency reserve drain simulation
- Chainlink detection & circuit breaker trigger
- Failed deposit attempt (bank run prevented)

---

## 🏗️ Architecture

```
User Actions → ReserveManager → USDC Reserves
                    ↓
                USDSToken (checks circuit breaker)
                    ↓
            SafeguardCircuitBreaker ← Chainlink DON
                                      (monitors every 60s)
```

**Full Architecture Diagram:** [See PROJECT_DESCRIPTION.md](./PROJECT_DESCRIPTION.md)

---

## 🔗 Chainlink Integration Files

### **Core CRE Workflow**
📄 **[workflow/main.ts](./workflow/main.ts)** - Main Chainlink Runtime Environment workflow
- **Lines 68-93:** `readOnchainReserves()` - Uses EVMClient to read USDC balance from blockchain
- **Lines 102-131:** `readOnchainSupply()` - Uses EVMClient to read USDS totalSupply()
- **Lines 165-185:** `submitOnchainReport()` - Uses DON signing + EVMClient writeReport
- **Lines 192-246:** `onHealthCheck()` - Main cron-triggered health check loop

### **Workflow Configuration**
📄 **[workflow/workflow.yaml](./workflow/workflow.yaml)** - CRE workflow configuration
📄 **[workflow/config.staging.json](./workflow/config.staging.json)** - Sepolia testnet config
📄 **[workflow/package.json](./workflow/package.json)** - Dependencies including `@chainlink/cre-sdk`

### **Smart Contracts (Chainlink Consumer)**
📄 **[contracts/src/SafeguardCircuitBreaker.sol](./contracts/src/SafeguardCircuitBreaker.sol)** - Receives Chainlink reports
- **Lines 28-254:** Full circuit breaker implementation
- **Line 38:** `address public immutable forwarder` - Chainlink KeystoneForwarder
- **Lines 95-153:** `onReport()` - Callback receiving DON-signed reports
- **Lines 232-252:** `getHealthSnapshot()` - Public view function for current state

📄 **[contracts/src/IReceiver.sol](./contracts/src/IReceiver.sol)** - Chainlink CRE consumer interface

### **Deployment Scripts**
📄 **[contracts/script/DeployAll.s.sol](./contracts/script/DeployAll.s.sol)** - Foundry deployment
- **Line 37:** Chainlink Forwarder address configuration

---

## 🚀 Quick Start

### **Prerequisites**
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Bun](https://bun.sh) v1.1+
- [Chainlink CRE CLI](https://docs.chain.link/cre): `npm install -g @chainlink/cre-cli`
- Sepolia ETH from [faucet.chainlink.com](https://faucets.chain.link/sepolia)
- Sepolia USDC from [faucet.circle.com](https://faucet.circle.com/)

### **1. Clone Repository**

```bash
git clone https://github.com/YOUR_USERNAME/defi-safeguard-engine.git
cd defi-safeguard-engine
```

### **2. Install Dependencies**

```bash
# Solidity dependencies
cd contracts
forge install

# Workflow dependencies
cd ../workflow
bun install
```

### **3. Configure Environment**

```bash
# Copy environment template
cp .env.example .env

# Edit .env with your values:
# - CRE_ETH_PRIVATE_KEY (no 0x prefix)
# - SEPOLIA_RPC_URL (Alchemy/Infura)
# - ETHERSCAN_API_KEY
```

### **4. Deploy Contracts**

```bash
cd contracts
source ../.env

forge script script/DeployAll.s.sol:DeployAll \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

**Copy the printed addresses into** `workflow/config.staging.json`

### **5. Test Workflow**

```bash
cd ../workflow

# Simulate (dry run)
cre workflow simulate workflow --target staging-settings --trigger-index 0

# Deploy to Chainlink DON
cre workflow deploy workflow --target staging-settings
```

---

## 📊 Live Demo Flow

### **Step 1: Initial Deposit (Healthy State)**
```bash
# Approve USDC
cast send 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
  "approve(address,uint256)" \
  0x28A45376815eed9D91cF4D446961a413cB4217A4 \
  20000000 \
  --rpc-url $SEPOLIA_RPC_URL

# Deposit 20 USDC
cast send 0x28A45376815eed9D91cF4D446961a413cB4217A4 \
  "deposit(uint256)" \
  20000000 \
  --rpc-url $SEPOLIA_RPC_URL
```

**Result:** Reserves: 20 USDC, Supply: 20 USDS → 100% ratio ✅

### **Step 2: Simulate Reserve Drain**
```bash
# Emergency withdraw 10 USDC
cast send 0x28A45376815eed9D91cF4D446961a413cB4217A4 \
  "emergencyWithdraw(address,uint256)" \
  YOUR_ADDRESS \
  10000000 \
  --rpc-url $SEPOLIA_RPC_URL
```

**Result:** Reserves: 10 USDC, Supply: 20 USDS → 50% ratio 🚨

### **Step 3: Chainlink Detection**
```bash
# Run workflow (detects critical state)
cre workflow simulate workflow \
  --target staging-settings \
  --broadcast \
  --trigger-index 0
```

**Result:**
```
[SAFEGUARD] Reserve Ratio = 5000 bps (50%)
[SAFEGUARD] Risk Tier = TIER_3_CRITICAL_HALT
[SAFEGUARD] Transaction: 0x33b0970d...
```

### **Step 4: Verify Bank Run Prevention**
```bash
# Try to deposit (should REVERT)
cast send 0x28A45376815eed9D91cF4D446961a413cB4217A4 \
  "deposit(uint256)" \
  5000000 \
  --rpc-url $SEPOLIA_RPC_URL
```

**Expected:** `Error: execution reverted: ProtocolHalted()` ✅

---

## 🧪 Testing

### **Unit Tests (Foundry)**
```bash
cd contracts
forge test -vv
```

### **Integration Tests**
```bash
# Full simulation from deploy to halt
./scripts/integration-test.sh
```

---

## 📈 Performance Metrics

| Metric | Value |
|--------|-------|
| Detection Latency | 60 seconds (cron interval) |
| Response Time | 3 seconds (transaction confirmation) |
| Gas Cost (per report) | ~150,000 gas (~$0.10 on mainnet) |
| Oracle Nodes | 10 (Byzantine Fault Tolerant) |
| Consensus Required | 7 of 10 signatures |

---

## 🔐 Security

- ✅ **Audited OpenZeppelin contracts** (Ownable, ERC20)
- ✅ **Byzantine Fault Tolerant** - 7+ of 10 node consensus
- ✅ **Replay protection** - unique report IDs
- ✅ **Stale report guard** - 5 minute expiry
- ✅ **Finality protection** - only reads finalized blocks
- ✅ **Verified on Etherscan** - transparent source code

**Security Model Details:** [See PROJECT_DESCRIPTION.md](./PROJECT_DESCRIPTION.md#security-model)

---

## 🌐 Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| Circuit Breaker | [`0x17fcFED...f6Cf9`](https://sepolia.etherscan.io/address/0x17fcFED27096343235076D4cDf6b479C97aF6Cf9) |
| USDS Token | [`0xEaB5770...38146`](https://sepolia.etherscan.io/address/0xEaB57701bb9Eb40946f6Cc1652f16168C2738146) |
| Reserve Manager | [`0x28A4537...217A4`](https://sepolia.etherscan.io/address/0x28A45376815eed9D91cF4D446961a413cB4217A4) |

**Live Circuit Breaker Trigger:** [Transaction 0x33b0970d...](https://sepolia.etherscan.io/tx/0x33b0970dc5371f1219bae3903fa0f848cf3d16d4f72d6b163f3c26cc3d4845f4)

---

## 📚 Documentation

- **[PROJECT_DESCRIPTION.md](./PROJECT_DESCRIPTION.md)** - Full technical specification
- **[DEMO_GUIDE.md](./DEMO_GUIDE.md)** - Step-by-step demo instructions
- **[Chainlink CRE Docs](https://docs.chain.link/cre)** - Official CRE documentation

---

## 🎯 Use Cases

- **Stablecoins** - USDC/USDT-style asset-backed tokens
- **Tokenized T-Bills** - Ondo, OpenEden, Backed Finance
- **Wrapped Assets** - WBTC, cross-chain bridges
- **RWA Protocols** - Any 1:1 or over-collateralized token

---

## 🛣️ Roadmap

- [x] Core circuit breaker implementation
- [x] Chainlink CRE workflow integration
- [x] Sepolia testnet deployment
- [ ] Multi-tier response system optimization
- [ ] Mainnet deployment
- [ ] Support for multiple reserve assets
- [ ] Integration with DeFi aggregators
- [ ] Mobile monitoring dashboard

---

## 🤝 Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request with tests

---

## 📄 License

MIT License - see [LICENSE](./LICENSE)

---

## 🙏 Acknowledgments

- **Chainlink Labs** - For the Runtime Environment SDK
- **OpenZeppelin** - For secure smart contract libraries
- **Foundry** - For excellent Solidity tooling

---

## 📞 Contact

**Built for:** Chainlink CRE Hackathon 2026  
**GitHub:** https://github.com/YOUR_USERNAME/defi-safeguard-engine  
**Twitter:** @YourTwitter (optional)

---

**⚡ Powered by Chainlink Runtime Environment**
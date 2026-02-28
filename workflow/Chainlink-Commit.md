## 🔗 Chainlink Integration Files

### **Core CRE Workflow**
📄 **[workflow/main.ts](.././workflow/main.ts)** - Main Chainlink Runtime Environment workflow
- **Lines 68-93:** `readOnchainReserves()` - Uses EVMClient to read USDC balance from blockchain
- **Lines 102-131:** `readOnchainSupply()` - Uses EVMClient to read USDS totalSupply()
- **Lines 165-185:** `submitOnchainReport()` - Uses DON signing + EVMClient writeReport
- **Lines 192-246:** `onHealthCheck()` - Main cron-triggered health check loop

### **Workflow Configuration**
📄 **[workflow/workflow.yaml](.././workflow.yaml)** - CRE workflow configuration
📄 **[workflow/config.staging.json](.././config.staging.json)** - Sepolia testnet config
📄 **[workflow/package.json](.././package.json)** - Dependencies including `@chainlink/cre-sdk`

### **Smart Contracts (Chainlink Consumer)**
📄 **[contracts/src/SafeguardCircuitBreaker.sol](.././contracts/src/Safeguardcircuitbreaker.sol)** - Receives Chainlink reports
- **Lines 28-254:** Full circuit breaker implementation
- **Line 38:** `address public immutable forwarder` - Chainlink KeystoneForwarder
- **Lines 95-153:** `onReport()` - Callback receiving DON-signed reports
- **Lines 232-252:** `getHealthSnapshot()` - Public view function for current state

📄 **[contracts/src/IReceiver.sol](.././contracts/src/IReceiver.sol)** - Chainlink CRE consumer interface
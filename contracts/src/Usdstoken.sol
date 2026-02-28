// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title USDSToken
 * @notice USD Stablecoin (USDS) - A Real-World Asset (RWA) backed stablecoin
 * 
 * USE CASE: This represents a USDC/USDT-style stablecoin where:
 *   - A protocol holds USDC reserves in a smart contract
 *   - Users can mint USDS by depositing USDC
 *   - Users can redeem USDS back to USDC
 *   - The Chainlink Safeguard Engine monitors reserves vs supply every 60 seconds
 *   - If reserves drop below 101% backing → protocol automatically halts
 * 
 * HACKATHON DEMO FLOW:
 *   1. Users deposit USDC → receive USDS
 *   2. Safeguard engine confirms 105% backing → status: HEALTHY
 *   3. Simulate reserve drain (send USDC out)
 *   4. Safeguard detects 99% backing → triggers CRITICAL halt
 *   5. Mint/redeem functions revert → bank run prevented ✅
 */
contract USDSToken is ERC20, Ownable {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// @notice The Chainlink circuit breaker that monitors reserve health
    address public circuitBreaker;
    
    /// @notice The reserve manager contract (holds USDC collateral)
    address public reserveManager;
    
    /// @notice Tracks if emergency pause is active (circuit breaker triggered)
    bool public emergencyPaused;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    event CircuitBreakerUpdated(address indexed oldBreaker, address indexed newBreaker);
    event EmergencyPauseActivated(address indexed by);
    event EmergencyPauseLifted(address indexed by);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    
    error ProtocolHalted();
    error MintingPaused();
    error OnlyReserveManager();
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @param _circuitBreaker Address of SafeguardCircuitBreaker contract
     * @param _reserveManager Address of ReserveManager contract
     * @param _owner Initial owner (receives admin rights)
     */
    constructor(
        address _circuitBreaker,
        address _reserveManager,
        address _owner
    ) ERC20("USD Stablecoin", "USDS") Ownable(_owner) {
        if (_circuitBreaker == address(0) || _reserveManager == address(0)) {
            revert ZeroAddress();
        }
        circuitBreaker = _circuitBreaker;
        reserveManager = _reserveManager;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Checks if the Chainlink safeguard has detected critical under-collateralization
     * @dev Reads isProtocolPaused from the circuit breaker contract
     *      If true → protocol is frozen → this modifier reverts all transactions
     */
    modifier whenNotHalted() {
        // Read the pause state from the circuit breaker
        (bool protocolPaused,,,,,) = ICircuitBreaker(circuitBreaker).getHealthSnapshot();
        
        if (protocolPaused || emergencyPaused) {
            revert ProtocolHalted();
        }
        _;
    }
    
    /**
     * @notice Checks if minting is allowed (stricter than full halt)
     * @dev Minting can be paused even if redemptions are still allowed
     */
    modifier whenMintingEnabled() {
        (, bool mintingPaused,,,,) = ICircuitBreaker(circuitBreaker).getHealthSnapshot();
        
        if (mintingPaused) {
            revert MintingPaused();
        }
        _;
    }
    
    modifier onlyReserveManager() {
        if (msg.sender != reserveManager) {
            revert OnlyReserveManager();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Mint new USDS tokens (called by ReserveManager when user deposits USDC)
     * @dev HACKATHON KEY POINT: This will REVERT if safeguard detected low reserves
     * @param to Address receiving the newly minted USDS
     * @param amount Amount of USDS to mint (18 decimals)
     */
    function mint(address to, uint256 amount) 
        external 
        onlyReserveManager 
        whenNotHalted 
        whenMintingEnabled 
    {
        _mint(to, amount);
    }
    
    /**
     * @notice Burn USDS tokens (called by ReserveManager when user redeems)
     * @dev HACKATHON KEY POINT: This will REVERT if protocol is halted
     * @param from Address whose USDS is being burned
     * @param amount Amount of USDS to burn
     */
    function burn(address from, uint256 amount) 
        external 
        onlyReserveManager 
        whenNotHalted 
    {
        _burn(from, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Update the circuit breaker address (e.g., after upgrading safeguard)
     */
    function setCircuitBreaker(address _newBreaker) external onlyOwner {
        if (_newBreaker == address(0)) revert ZeroAddress();
        emit CircuitBreakerUpdated(circuitBreaker, _newBreaker);
        circuitBreaker = _newBreaker;
    }
    
    /**
     * @notice Update the reserve manager address
     * @dev Can only be called by owner, useful for deployment or upgrades
     */
    function setReserveManager(address _newManager) external onlyOwner {
        if (_newManager == address(0)) revert ZeroAddress();
        reserveManager = _newManager;
    }
    
    /**
     * @notice Manual emergency pause (in case circuit breaker fails)
     */
    function emergencyPause() external onlyOwner {
        emergencyPaused = true;
        emit EmergencyPauseActivated(msg.sender);
    }
    
    /**
     * @notice Lift manual emergency pause
     */
    function unpause() external onlyOwner {
        emergencyPaused = false;
        emit EmergencyPauseLifted(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Check if protocol is currently operational
     * @return healthy True if minting/burning is allowed
     */
    function isHealthy() external view returns (bool healthy) {
        (bool protocolPaused, bool mintingPaused,,,,) = 
            ICircuitBreaker(circuitBreaker).getHealthSnapshot();
        
        return !protocolPaused && !mintingPaused && !emergencyPaused;
    }
}

/**
 * @notice Minimal interface to read circuit breaker state
 */
interface ICircuitBreaker {
    function getHealthSnapshot() external view returns (
        bool protocolPaused,
        bool mintingPaused,
        bool swapsPaused,
        uint256 ratioBps,
        uint8 tier,
        uint256 lastUpdate
    );
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ReserveManager
 * @notice Manages USDC reserves and mints/burns USDS tokens
 * 
 * HACKATHON DEMO EXPLANATION:
 * ===========================
 * This contract acts as the "bank vault" for the stablecoin:
 * 
 * USER DEPOSITS USDC:
 *   1. User calls deposit(1000 USDC)
 *   2. Contract receives USDC → stores it as reserves
 *   3. Contract mints 1000 USDS to user
 *   4. Chainlink engine reads: reserves = 1000 USDC, supply = 1000 USDS
 *   5. Ratio = 100% → HEALTHY ✅
 * 
 * USER REDEEMS USDS:
 *   1. User calls redeem(500 USDS)
 *   2. Contract burns 500 USDS
 *   3. Contract sends 500 USDC back to user
 *   4. New state: reserves = 500 USDC, supply = 500 USDS → still 100%
 * 
 * DEMO SCENARIO - SIMULATE RESERVE DRAIN:
 *   1. Owner calls emergencyWithdraw(200 USDC) → simulates hack/loss
 *   2. New state: reserves = 300 USDC, supply = 500 USDS
 *   3. Ratio = 60% → CRITICAL 🚨
 *   4. Next Chainlink health check → circuit breaker HALTS protocol
 *   5. Users calling deposit() or redeem() → transaction REVERTS
 *   6. Bank run prevented! 🛡️
 */
contract ReserveManager is Ownable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// @notice USDC token (the reserve asset) - Sepolia: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
    IERC20 public immutable reserveToken;
    
    /// @notice USDS token (the stablecoin we issue)
    IUSDSToken public immutable usdsToken;
    
    /// @notice Minimum reserve ratio in basis points (10100 = 101%)
    uint256 public minReserveRatioBps = 10100;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    event Deposited(address indexed user, uint256 usdcAmount, uint256 usdsAmount);
    event Redeemed(address indexed user, uint256 usdsAmount, uint256 usdcAmount);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event MinReserveRatioUpdated(uint256 oldRatio, uint256 newRatio);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    
    error ZeroAmount();
    error InsufficientReserves();
    error TransferFailed();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @param _reserveToken Address of USDC token (reserves)
     * @param _usdsToken Address of USDS token (stablecoin)
     * @param _owner Initial owner
     */
    constructor(
        address _reserveToken,
        address _usdsToken,
        address _owner
    ) Ownable(_owner) {
        reserveToken = IERC20(_reserveToken);
        usdsToken = IUSDSToken(_usdsToken);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // USER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Deposit USDC to mint USDS (1:1 ratio)
     * @dev HACKATHON DEMO: Call this to simulate normal user minting
     * @param usdcAmount Amount of USDC to deposit (6 decimals)
     * 
     * DEMO STEPS:
     *   1. User approves this contract to spend USDC
     *   2. User calls deposit(1000e6) → deposits 1000 USDC
     *   3. Contract mints 1000e18 USDS (converts 6 decimals → 18 decimals)
     *   4. Chainlink engine sees: reserves++, supply++ → ratio stays healthy
     */
    function deposit(uint256 usdcAmount) external {
        if (usdcAmount == 0) revert ZeroAmount();
        
        // STEP 1: Transfer USDC from user to this contract (reserves)
        reserveToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
        
        // STEP 2: Convert USDC (6 decimals) to USDS (18 decimals)
        // 1000 USDC (1000e6) → 1000 USDS (1000e18)
        uint256 usdsAmount = usdcAmount * 1e12; // 6 → 18 decimals
        
        // STEP 3: Mint USDS to user
        // NOTE: This will REVERT if circuit breaker detected low reserves
        usdsToken.mint(msg.sender, usdsAmount);
        
        emit Deposited(msg.sender, usdcAmount, usdsAmount);
    }
    
    /**
     * @notice Redeem USDS to get USDC back (1:1 ratio)
     * @dev HACKATHON DEMO: Call this to simulate redemption
     * @param usdsAmount Amount of USDS to burn (18 decimals)
     * 
     * DEMO STEPS:
     *   1. User calls redeem(500e18) → burns 500 USDS
     *   2. Contract sends 500 USDC back to user
     *   3. Chainlink engine sees: reserves--, supply-- → ratio stays same
     */
    function redeem(uint256 usdsAmount) external {
        if (usdsAmount == 0) revert ZeroAmount();
        
        // STEP 1: Convert USDS (18 decimals) to USDC (6 decimals)
        uint256 usdcAmount = usdsAmount / 1e12;
        
        // STEP 2: Check we have enough USDC reserves
        if (reserveToken.balanceOf(address(this)) < usdcAmount) {
            revert InsufficientReserves();
        }
        
        // STEP 3: Burn user's USDS
        // NOTE: This will REVERT if protocol is halted
        usdsToken.burn(msg.sender, usdsAmount);
        
        // STEP 4: Send USDC back to user
        reserveToken.safeTransfer(msg.sender, usdcAmount);
        
        emit Redeemed(msg.sender, usdsAmount, usdcAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEMO FUNCTIONS (FOR HACKATHON TESTING)
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Emergency withdraw reserves (DEMO ONLY - simulates reserve drain)
     * @dev HACKATHON USE: Call this to artificially lower reserves and trigger circuit breaker
     * 
     * DEMO SCENARIO:
     *   Current: 1000 USDC reserves, 1000 USDS supply → 100% ratio
     *   Owner calls emergencyWithdraw(500 USDC)
     *   New: 500 USDC reserves, 1000 USDS supply → 50% ratio
     *   Chainlink detects 50% < 101% → CRITICAL HALT triggered
     *   Users can no longer mint/redeem → protocol frozen ✅
     */
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        
        uint256 balance = reserveToken.balanceOf(address(this));
        if (balance < amount) revert InsufficientReserves();
        
        reserveToken.safeTransfer(to, amount);
        emit EmergencyWithdrawal(to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Get current reserve ratio (for monitoring)
     * @return ratioBps Reserve ratio in basis points (10000 = 100%)
     * 
     * HACKATHON DEMO: Display this on your frontend/dashboard
     */
    function getReserveRatio() external view returns (uint256 ratioBps) {
        uint256 totalSupply = usdsToken.totalSupply();
        if (totalSupply == 0) return 0;
        
        // Convert USDC reserves (6 decimals) to 18 decimals for calculation
        uint256 reserves = reserveToken.balanceOf(address(this)) * 1e12;
        
        // Calculate ratio: (reserves / supply) * 10000
        ratioBps = (reserves * 10000) / totalSupply;
    }
    
    /**
     * @notice Get current USDC reserves held by this contract
     * @return reserves Amount of USDC (6 decimals)
     */
    function getReserves() external view returns (uint256 reserves) {
        return reserveToken.balanceOf(address(this));
    }
}

/**
 * @notice Minimal interface for USDS token
 */
interface IUSDSToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

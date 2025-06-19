// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FLASHFLOW
 * @dev A decentralized flash loan aggregator and liquidity management platform
 * @author FlashFlow Team
 */
contract Project is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // State variables
    mapping(address => uint256) public liquidityPools;
    mapping(address => mapping(address => uint256)) public userDeposits;
    mapping(address => bool) public supportedTokens;
    mapping(address => uint256) public flashLoanFees; // Basis points (e.g., 30 = 0.3%)
    
    uint256 public constant MAX_FLASH_LOAN_FEE = 1000; // 10% maximum fee
    uint256 public totalValueLocked;
    
    // Events
    event LiquidityAdded(address indexed user, address indexed token, uint256 amount);
    event LiquidityRemoved(address indexed user, address indexed token, uint256 amount);
    event FlashLoanExecuted(address indexed borrower, address indexed token, uint256 amount, uint256 fee);
    event TokenSupported(address indexed token, uint256 flashLoanFee);
    
    // Errors
    error InsufficientLiquidity();
    error UnsupportedToken();
    error InvalidFee();
    error FlashLoanNotRepaid();
    
    constructor() {}
    
    /**
     * @dev Core Function 1: Add liquidity to the platform
     * @param token The ERC20 token address
     * @param amount The amount of tokens to deposit
     */
    function addLiquidity(address token, uint256 amount) external nonReentrant {
        if (!supportedTokens[token]) revert UnsupportedToken();
        if (amount == 0) revert InvalidFee();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        userDeposits[msg.sender][token] += amount;
        liquidityPools[token] += amount;
        totalValueLocked += amount;
        
        emit LiquidityAdded(msg.sender, token, amount);
    }
    
    /**
     * @dev Core Function 2: Remove liquidity from the platform
     * @param token The ERC20 token address
     * @param amount The amount of tokens to withdraw
     */
    function removeLiquidity(address token, uint256 amount) external nonReentrant {
        if (userDeposits[msg.sender][token] < amount) revert InsufficientLiquidity();
        if (liquidityPools[token] < amount) revert InsufficientLiquidity();
        
        userDeposits[msg.sender][token] -= amount;
        liquidityPools[token] -= amount;
        totalValueLocked -= amount;
        
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit LiquidityRemoved(msg.sender, token, amount);
    }
    
    /**
     * @dev Core Function 3: Execute flash loan
     * @param token The ERC20 token address to borrow
     * @param amount The amount to borrow
     * @param data Additional data for flash loan execution
     */
    function executeFlashLoan(
        address token,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant {
        if (!supportedTokens[token]) revert UnsupportedToken();
        if (liquidityPools[token] < amount) revert InsufficientLiquidity();
        
        uint256 fee = (amount * flashLoanFees[token]) / 10000;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        
        // Transfer tokens to borrower
        IERC20(token).safeTransfer(msg.sender, amount);
        
        // Execute borrower's logic
        IFlashLoanReceiver(msg.sender).receiveFlashLoan(token, amount, fee, data);
        
        // Check if loan + fee is repaid
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore + fee) revert FlashLoanNotRepaid();
        
        // Update liquidity pool with earned fees
        liquidityPools[token] += fee;
        
        emit FlashLoanExecuted(msg.sender, token, amount, fee);
    }
    
    /**
     * @dev Core Function 4: Optimize liquidity across multiple pools
     * @param tokens Array of token addresses to optimize
     * @param targetAllocations Array of target allocation percentages (basis points)
     */
    function optimizeLiquidity(
        address[] calldata tokens,
        uint256[] calldata targetAllocations
    ) external onlyOwner {
        require(tokens.length == targetAllocations.length, "Arrays length mismatch");
        
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < targetAllocations.length; i++) {
            totalAllocation += targetAllocations[i];
        }
        require(totalAllocation == 10000, "Total allocation must be 100%");
        
        uint256 totalLiquidity = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            totalLiquidity += liquidityPools[tokens[i]];
        }
        
        // Rebalance liquidity based on target allocations
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 targetAmount = (totalLiquidity * targetAllocations[i]) / 10000;
            uint256 currentAmount = liquidityPools[tokens[i]];
            
            if (targetAmount > currentAmount) {
                // Need to add liquidity to this pool
                uint256 deficit = targetAmount - currentAmount;
                _rebalanceFromOtherPools(tokens[i], deficit, tokens);
            }
        }
    }
    
    // Internal function for liquidity rebalancing
    function _rebalanceFromOtherPools(
        address targetToken,
        uint256 neededAmount,
        address[] calldata tokens
    ) internal {
        uint256 transferred = 0;
        
        for (uint256 i = 0; i < tokens.length && transferred < neededAmount; i++) {
            if (tokens[i] != targetToken && liquidityPools[tokens[i]] > 0) {
                uint256 transferAmount = liquidityPools[tokens[i]] / 10; // Transfer 10% max
                if (transferAmount > neededAmount - transferred) {
                    transferAmount = neededAmount - transferred;
                }
                
                liquidityPools[tokens[i]] -= transferAmount;
                liquidityPools[targetToken] += transferAmount;
                transferred += transferAmount;
            }
        }
    }
    
    // Admin functions
    function addSupportedToken(address token, uint256 feeInBasisPoints) external onlyOwner {
        if (feeInBasisPoints > MAX_FLASH_LOAN_FEE) revert InvalidFee();
        
        supportedTokens[token] = true;
        flashLoanFees[token] = feeInBasisPoints;
        
        emit TokenSupported(token, feeInBasisPoints);
    }
    
    function updateFlashLoanFee(address token, uint256 feeInBasisPoints) external onlyOwner {
        if (!supportedTokens[token]) revert UnsupportedToken();
        if (feeInBasisPoints > MAX_FLASH_LOAN_FEE) revert InvalidFee();
        
        flashLoanFees[token] = feeInBasisPoints;
    }
    
    // View functions
    function getAvailableLiquidity(address token) external view returns (uint256) {
        return liquidityPools[token];
    }
    
    function getUserDeposit(address user, address token) external view returns (uint256) {
        return userDeposits[user][token];
    }
    
    function calculateFlashLoanFee(address token, uint256 amount) external view returns (uint256) {
        return (amount * flashLoanFees[token]) / 10000;
    }
}

// Interface for flash loan receivers
interface IFlashLoanReceiver {
    function receiveFlashLoan(
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}

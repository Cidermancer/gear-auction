// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { GearLiquidityBootstrapper } from "./GearLiquidityBootstrapper.sol";

import { IGearToken } from "./interfaces/IGearToken.sol";
import { ICurvePool } from "./interfaces/ICurvePool.sol";
import { ICurveFactory } from "./interfaces/ICurveFactory.sol";

import "./constants2.sol";

enum Stage {
    INITIALIZED,
    GEAR_DEPOSIT,
    ETH_DEPOSIT,
    FAIR_TRADING,
    FINISHED,
    FAILED
}

contract GearLiquidityBootstrapper2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    // EVENTS

    event StageChanged(Stage newStage);

    event EthCommitted(address indexed contributor, uint256 amount);

    event PoolDeployed(address indexed pool);

    event PoolSeeded(uint256 initialGEAR, uint256 initialETH, uint256 initialLP);

    event GearSold(address indexed seller, uint256 amount, uint256 shearedAmount);

    event GearBought(address indexed buyer, uint256 amount);

    event GearTransfersUnlocked();

    event LPClaimed(address indexed contributor, uint256 amount);

    // GEAR DEPOSIT PARAMS

    // GEAR token
    IGearToken public constant gear = IGearToken(GEAR_TOKEN);

    // Previous GearLiquidityBootstrapper contract
    address public constant glb1 = GEAR_LIQUIDITY_BOOTSTRAPPER_1;

    // Stores whether the user already spent their GEAR by claiming LP or withdrawing
    mapping(address => bool) public gearSpent;

    // Total amount of GEAR currently committed
    uint256 public totalGearCommitted;

    // ETH DEPOSIT PARAMS

    // Max ETH amount collected
    uint256 public constant ethMaxAmount = ETH_MAX_AMOUNT;

    // Min ETH amount collected
    uint256 public constant ethMinAmount = ETH_MIN_AMOUNT;

    // ETH amounts committed by contributors
    mapping(address => uint256) public ethCommitted;

    // Total amount of ETH currently committed
    uint256 public totalEthCommitted;

    // Timestamp of ETH deposit beginning
    uint256 public constant ethDepositStart = ETH_DEPOSIT_START;

    // FAIR TRADING PARAMETERS

    // Start of GEAR discounted selling
    uint256 public constant fairTradingStart = ETH_DEPOSIT_START + ETH_DEPOSIT_DURATION;

    // End of GEAR discounted selling
    uint256 public constant fairTradingEnd = ETH_DEPOSIT_START + ETH_DEPOSIT_DURATION + FAIR_TRADING_DURATION;
    
    // Duration of GEAR discounted selling
    uint256 public constant fairTradingDuration = FAIR_TRADING_DURATION;

    // Initial shearing percentage for GEAR selling (in 1e18 format)
    uint256 public constant shearingPctStart = STARTING_SHEARING_PCT;

    uint256 public constant SHEARING_PCT_DENOMINATOR = 10 ** 18;

    // FINISHED STAGE PARAMETERS

    // Total amount of LP tokens minted by the pool after liquidity deposit
    uint256 public totalLPTokens;

    // CURVE DEPLOY PARAMS

    // Address of the Curve factory for crypto pools
    ICurveFactory public constant curveFactory = ICurveFactory(CURVE_FACTORY);

    // WETH address (must be used as one of the Crypto pool assets)
    address public constant weth = WETH20;

    // Curve pool deployment parameters
    uint256 public constant curvePool_A = DEFAULT_A;
    uint256 public constant curvePool_gamma = DEFAULT_GAMMA;
    uint256 public constant curvePool_mid_fee = DEFAULT_MID_FEE;
    uint256 public constant curvePool_out_fee = DEFAULT_OUT_FEE;
    uint256 public constant curvePool_allowed_extra_profit = DEFAULT_ALLOWED_EXTRA_PROFIT;
    uint256 public constant curvePool_fee_gamma = DEFAULT_FEE_GAMMA;
    uint256 public constant curvePool_adjustment_step = DEFAULT_ADJUSTMENT_STEP;
    uint256 public constant curvePool_admin_fee = DEFAULT_ADMIN_FEE;
    uint256 public constant curvePool_ma_half_time = DEFAULT_MA_HALF_TIME;

    uint256 public constant PRICE_MULTIPLIER = 10 ** 18;

    // GLOBAL PARAMS

    // Current stage
    Stage public stage = Stage.INITIALIZED;

    // GEAR/ETH Curve pool (after it's deployed)
    ICurvePool public curvePool;

    constructor() {
        _transferOwnership(GEARBOX_TREASURY);
    }

    modifier withMinerSwitch(address newMiner) {
        address oldMiner = gear.miner();
        gear.setMiner(newMiner);
        _;
        gear.setMiner(oldMiner);
    }

    // ADMIN FUNCTIONS 

    function setGearMiner(
        address newMiner
    ) external onlyOwner {
        gear.setMiner(newMiner);
    }

    function fail() external onlyOwner {
        _fail();
    }

    function execute(address target, bytes memory data)
        external
        onlyOwner
        returns (bytes memory)
    {
        return target.functionCall(data);
    }

    function inheritGLB1() external onlyOwner {
        uint256 gearBalance = gear.balanceOf(glb1);
        totalGearCommitted = gearBalance;
        gear.transferFrom(glb1, address(this), gearBalance);
    }

    // STAGE LOGIC

    modifier onlyStage(Stage requiredStage) {

        _advanceStage();

        require(
            stage == requiredStage,
            "Can't be called during the current stage"
        );
        _;
    }

    function _advanceStage() internal {

        Stage currentStage = stage;

        if (currentStage == Stage.FINISHED || currentStage == Stage.FAILED) {
            return;
        }

        if (currentStage == Stage.INITIALIZED) {
            if (block.timestamp >= ethDepositStart) {
                if (block.timestamp >= fairTradingStart) {
                    _fail();
                } else {
                    _startEthDeposit();
                }
            } 
            return;
        }
        
        if (currentStage == Stage.ETH_DEPOSIT && block.timestamp >= fairTradingStart) {
            if (totalEthCommitted >= ethMinAmount) {
                if (block.timestamp >= fairTradingEnd) {
                    _finish();
                } else {
                    _startFairTrading();
                }
            } else {
                _fail();
            }
            return;
        } 
        
        if (currentStage == Stage.FAIR_TRADING && block.timestamp >= fairTradingEnd) {
            _finish();
        }
    }

    function advanceStage() external {
        _advanceStage();
    }

    function _startEthDeposit() internal {
        stage = Stage.ETH_DEPOSIT;
        emit StageChanged(Stage.ETH_DEPOSIT);
    }

    function _startFairTrading() internal {
        _deployPool();
        _depositToPool();

        stage = Stage.FAIR_TRADING;

        emit StageChanged(Stage.FAIR_TRADING);
    }

    function _finish() internal {
        _unlockGEAR();

        stage = Stage.FINISHED;
        emit StageChanged(Stage.FINISHED);
    }

    function _fail() internal {
        stage = Stage.FAILED;
        emit StageChanged(Stage.FAILED);
    }

    function _deployPool() internal {
        uint256 initialPrice = totalGearCommitted * PRICE_MULTIPLIER / totalEthCommitted;

        address poolAddress = curveFactory.deploy_pool(
            "Curve GEAR/ETH",
            "crvGEARETH",
            [address(gear), address(weth)],
            curvePool_A,
            curvePool_gamma,
            curvePool_mid_fee,
            curvePool_out_fee,
            curvePool_allowed_extra_profit,
            curvePool_fee_gamma,
            curvePool_adjustment_step,
            curvePool_admin_fee,
            curvePool_ma_half_time,
            initialPrice
        );

        curvePool = ICurvePool(poolAddress);

        gear.approve(address(curvePool), MAX_INT);

        emit PoolDeployed(poolAddress);
    }

    function _depositToPool() internal withMinerSwitch(address(curvePool)) {

        uint256 totalEthCommitted_ = totalEthCommitted;
        uint256 totalGearCommitted_ = totalGearCommitted;

        totalLPTokens = curvePool.add_liquidity{value: totalEthCommitted_}([totalGearCommitted_, totalEthCommitted_], 0, true);

        emit PoolSeeded(totalGearCommitted_, totalEthCommitted_, totalLPTokens);
    }

    function _unlockGEAR() internal {
        gear.allowTransfers();
        gear.setMiner(address(gear));
        gear.transferOwnership(address(gear));

        emit GearTransfersUnlocked();
    }

    // ETH DEPOSIT LOGIC

    function commitETH() external payable onlyStage(Stage.ETH_DEPOSIT) {
        _commitETH();
    }

    receive() external payable {

        Stage stage_ = stage;

        if (stage_ == Stage.ETH_DEPOSIT) {
            _commitETH();
        } else if (stage_ == Stage.FAIR_TRADING && msg.sender == address(curvePool)) {}
        else {
           revert("Can't be called during the current stage");
        } 

       
    }

    function _commitETH() internal nonReentrant {

        uint256 amount = msg.value;
        uint256 totalEthCommitted_ = totalEthCommitted;

        if (totalEthCommitted_ + amount > ethMaxAmount) {
            amount = ethMaxAmount - totalEthCommitted_;
            payable(msg.sender).call{value: msg.value - amount}("");
        }

        require(
            amount > 0,
            "Nothing to commit"
        );

        ethCommitted[msg.sender] += amount;
        totalEthCommitted += amount;

        emit EthCommitted(msg.sender, amount);
    }

    // FAIR TRADING LOGIC

    function sellGEAR(uint256 amount, uint256 minETHBack) external onlyStage(Stage.FAIR_TRADING) nonReentrant {

        gear.transferFrom(msg.sender, address(this), amount);

        uint256 currentShearingPct = getCurrentShearingPct();

        uint256 shearedAmount = amount * currentShearingPct / SHEARING_PCT_DENOMINATOR;
        uint256 amountToSell = amount - shearedAmount;

        uint256 ethReceived = _sellGEARWithMinerPool(amountToSell, minETHBack);

        payable(msg.sender).call{value: ethReceived}("");

        emit GearSold(msg.sender, amountToSell, shearedAmount);
    }

    function _sellGEARWithMinerPool(uint256 amount, uint256 minETHBack) internal withMinerSwitch(address(curvePool)) returns (uint256) {
        return curvePool.exchange(0, 1, amount, minETHBack, true, address(this));
    }

    function buyGEAR(uint256 minGEARBack) external payable onlyStage(Stage.FAIR_TRADING) withMinerSwitch(address(curvePool)) nonReentrant {

        uint256 ethAmount = msg.value;

        uint256 gearAmount = curvePool.exchange{value: ethAmount}(1, 0, ethAmount, minGEARBack, true, msg.sender);

        emit GearBought(msg.sender, gearAmount);
    }

    function getCurrentShearingPct() public view returns (uint256) {
        if (block.timestamp < fairTradingStart) {
            return shearingPctStart;
        } else if (block.timestamp >= fairTradingEnd) {
            return 0;
        } else {
            return shearingPctStart * (fairTradingEnd - block.timestamp) / fairTradingDuration;
        }
    }

    function getETHFromGEARAmount(uint256 amount) external view returns (uint256) {

        if (stage < Stage.FAIR_TRADING) {
            return 0;
        }

        uint256 currentShearingPct = getCurrentShearingPct();
        uint256 amountToSell = amount - amount * currentShearingPct / SHEARING_PCT_DENOMINATOR;

        return curvePool.get_dy(0, 1, amountToSell);
    }

    function getGEARFromETHAmount(uint256 amount) external view returns (uint256) {
        return curvePool.get_dy(1, 0, amount);
    }

    // FINISHED LOGIC

    function claimLP() external onlyStage(Stage.FINISHED) {

        uint256 lpAmount = getPendingLPAmount();

        require(
            lpAmount != 0,
            "Nothing to claim"
        );

        gearSpent[msg.sender] = true;
        ethCommitted[msg.sender] = 0;

        IERC20(curvePool.token()).safeTransfer(msg.sender, lpAmount);

        emit LPClaimed(msg.sender, lpAmount);
    }

    function retrieveShearedGEAR() external onlyStage(Stage.FINISHED) onlyOwner {
        gear.transfer(owner(), gear.balanceOf(address(this)));
    }

    // FAILED LOGIC

    function retrieveGEAR() external onlyStage(Stage.FAILED) {

        uint256 amount = gearCommitted(msg.sender);
        gearSpent[msg.sender] = true;

        gear.transfer(msg.sender, amount);
    }

    function retrieveETH() external onlyStage(Stage.FAILED) nonReentrant {

        uint256 amount = ethCommitted[msg.sender];
        ethCommitted[msg.sender] = 0;

        payable(msg.sender).call{value: amount}("");
    }

    function takeGEARManagerBack() external onlyStage(Stage.FAILED) onlyOwner {
        gear.transferOwnership(owner());
    }

    // CONVENIENCE GETTERS

    function _getCurrentMinMaxAmounts() internal view returns(uint256 totalGear, uint256 minEth, uint256 maxEth) {

        uint256 totalEthCommitted_ = totalEthCommitted;

        totalGear = totalGearCommitted;
        minEth = totalEthCommitted_ <= ethMinAmount ? ethMinAmount : totalEthCommitted_;
        maxEth = block.timestamp >= fairTradingStart ? totalEthCommitted_ : ethMaxAmount;
    }

    // Returns ETH / GEAR price range
    function getPriceRangeEthGear() external view returns (uint256 minPrice, uint256 maxPrice) {

        (uint256 totalGear, uint256 minEth, uint256 maxEth) = _getCurrentMinMaxAmounts();

        minPrice = minEth * PRICE_MULTIPLIER / totalGear;
        maxPrice = maxEth * PRICE_MULTIPLIER / totalGear;
    }

    // Returns GEAR / ETH price range
    function getPriceRangeGearEth() external view returns (uint256 minPrice, uint256 maxPrice) {

        (uint256 totalGear, uint256 minEth, uint256 maxEth) = _getCurrentMinMaxAmounts();

        minPrice = totalGear * PRICE_MULTIPLIER / maxEth;
        maxPrice = totalGear * PRICE_MULTIPLIER / minEth;
    }

    function getPendingLPAmount() public view returns (uint256 lpAmount) {

       uint256 totalLPTokens_ = totalLPTokens; 

       lpAmount = gearCommitted(msg.sender) * totalLPTokens_ / (2 * totalGearCommitted) + 
                           ethCommitted[msg.sender] * totalLPTokens_ / (2 * totalEthCommitted);
    }

    function getTimeUntilLPClaim() external view returns (uint256 lpAmount) {
        return fairTradingEnd > block.timestamp ? fairTradingEnd - block.timestamp : 0;
    }

    function gearCommitted(address account) public view returns (uint256) {
        return gearSpent[account] ? 0 : GearLiquidityBootstrapper(payable(glb1)).gearCommitted(account);
    }

}
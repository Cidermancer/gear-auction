// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IGearToken } from "./interfaces/IGearToken.sol";
import { ICurvePool } from "./interfaces/ICurvePool.sol";
import { ICurveFactory } from "./interfaces/ICurveFactory.sol";

import "./constants.sol";

enum Stage {
    INITIALIZED,
    GEAR_DEPOSIT,
    ETH_DEPOSIT,
    FAIR_TRADING,
    FINISHED,
    FAILED
}

contract GearLiquidityBootstrapper is Ownable, ReentrancyGuard {
    using SafeERC20 for IGearToken;
    using SafeERC20 for IERC20;
    using Address for address;

    // EVENTS

    event StageChanged(Stage newStage);

    event GearCommitted(address indexed contributor, uint256 amount);

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

    // Max GEAR amount collected
    uint256 public constant gearMaxAmount = GEAR_MAX_AMOUNT;

    // Min GEAR amount collected
    uint256 public constant gearMinAmount = GEAR_MIN_AMOUNT;

    // GEAR amounts committed by contributors
    mapping(address => uint256) public gearCommitted;

    // Total amount of GEAR currently committed
    uint256 public totalGearCommitted;

    // Timestamp of GEAR deposit beginning
    uint256 public constant gearDepositStart = GEAR_DEPOSIT_START;

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
    uint256 public constant ethDepositStart = GEAR_DEPOSIT_START + GEAR_DEPOSIT_DURATION;

    // FAIR TRADING PARAMETERS

    // Start of GEAR discounted selling
    uint256 public constant fairTradingStart = GEAR_DEPOSIT_START + GEAR_DEPOSIT_DURATION + ETH_DEPOSIT_DURATION;

    // End of GEAR discounted selling
    uint256 public constant fairTradingEnd = GEAR_DEPOSIT_START + GEAR_DEPOSIT_DURATION + ETH_DEPOSIT_DURATION + FAIR_TRADING_DURATION;

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
        _startGearDeposit();
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

        if (stage == Stage.INITIALIZED && block.timestamp >= gearDepositStart) {
            _startGearDeposit();
        } else if (stage == Stage.GEAR_DEPOSIT && block.timestamp >= ethDepositStart) {
            if (totalGearCommitted >= gearMinAmount) {
                _startEthDeposit();
            } else {
                _fail();
            }
        } else if (stage == Stage.ETH_DEPOSIT && block.timestamp >= fairTradingStart) {
            if (totalEthCommitted >= ethMinAmount) {
                _startFairTrading();
            } else {
                _fail();
            }
        } else if (stage == Stage.FAIR_TRADING && block.timestamp >= fairTradingEnd) {
            _finish();
        }
    }

    function advanceStage() external {
        _advanceStage();
    }

    function _startGearDeposit() internal {
        stage = Stage.GEAR_DEPOSIT;
        emit StageChanged(Stage.GEAR_DEPOSIT);
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
        uint256 initialPrice = totalEthCommitted * PRICE_MULTIPLIER / totalGearCommitted;

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
        totalLPTokens = curvePool.add_liquidity{value: totalEthCommitted}([totalGearCommitted, totalEthCommitted], 0, true);

        emit PoolSeeded(totalGearCommitted, totalEthCommitted, totalLPTokens);
    }

    function _unlockGEAR() internal {
        gear.allowTransfers();
        gear.setMiner(address(gear));
        gear.transferOwnership(address(gear));

        emit GearTransfersUnlocked();
    }

    // GEAR DEPOSIT LOGIC

    function commitGEAR(uint256 amount) external onlyStage(Stage.GEAR_DEPOSIT) {

        if (totalGearCommitted + amount > gearMaxAmount) {
            amount = gearMaxAmount - totalGearCommitted;
        }

        gear.safeTransferFrom(msg.sender, address(this), amount);
        gearCommitted[msg.sender] += amount;
        totalGearCommitted += amount;

        emit GearCommitted(msg.sender, amount);

        if (totalGearCommitted == gearMaxAmount) {
            _startEthDeposit();
        }
    }

    // ETH DEPOSIT LOGIC

    function commitETH() external payable nonReentrant onlyStage(Stage.ETH_DEPOSIT) {
        _commitETH();
    }

    receive() external payable nonReentrant onlyStage(Stage.ETH_DEPOSIT) {
        _commitETH();
    }

    function _commitETH() internal {

        uint256 amount = msg.value;

        if (totalEthCommitted + amount > ethMaxAmount) {
            amount = ethMaxAmount - totalEthCommitted;
            payable(msg.sender).transfer(msg.value - amount);
        }

        ethCommitted[msg.sender] += amount;
        totalEthCommitted += amount;

        emit EthCommitted(msg.sender, amount);

        if (totalEthCommitted == ethMaxAmount) {
            _startFairTrading();
        }
    }

    // FAIR TRADING LOGIC

    function sellGEAR(uint256 amount, uint256 minETHBack) external onlyStage(Stage.FAIR_TRADING) withMinerSwitch(address(curvePool)) nonReentrant {

        gear.safeTransferFrom(msg.sender, address(this), amount);

        uint256 currentShearingPct = shearingPctStart * (fairTradingEnd - block.timestamp) / (fairTradingEnd - fairTradingStart);

        uint256 shearedAmount = amount * currentShearingPct / SHEARING_PCT_DENOMINATOR;
        uint256 amountToSell = amount - shearedAmount;

        curvePool.exchange(0, 1, amountToSell, minETHBack, true, msg.sender);

        emit GearSold(msg.sender, amountToSell, shearedAmount);
    }

    function buyGEAR(uint256 minGEARBack) external payable onlyStage(Stage.FAIR_TRADING) withMinerSwitch(address(curvePool)) nonReentrant {

        uint256 ethAmount = msg.value;

        uint256 gearAmount = curvePool.exchange{value: ethAmount}(1, 0, ethAmount, minGEARBack, true, msg.sender);

        emit GearBought(msg.sender, gearAmount);
    }

    // FINISHED LOGIC

    function claimLP() external onlyStage(Stage.FINISHED) {

        uint256 lpAmount = getPendingLPAmount();

        require(
            lpAmount != 0,
            "Nothing to claim"
        );

        gearCommitted[msg.sender] = 0;
        ethCommitted[msg.sender] = 0;

        IERC20(curvePool.token()).safeTransfer(msg.sender, lpAmount);

        emit LPClaimed(msg.sender, lpAmount);
    }

    function retrieveShearedGEAR() external onlyStage(Stage.FINISHED) onlyOwner {
        gear.safeTransfer(owner(), gear.balanceOf(address(this)));
    }

    // FAILED LOGIC

    function retrieveGEAR() external onlyStage(Stage.FAILED) {

        uint256 amount = gearCommitted[msg.sender];
        gearCommitted[msg.sender] = 0;

        gear.safeTransfer(msg.sender, amount);
    }

    function retrieveETH() external onlyStage(Stage.FAILED) nonReentrant {

        uint256 amount = ethCommitted[msg.sender];
        ethCommitted[msg.sender] = 0;

        payable(msg.sender).transfer(amount);
    }

    function takeGEARManagerBack() external onlyStage(Stage.FAILED) onlyOwner {
        gear.transferOwnership(owner());
    }

    // CONVENIENCE GETTERS

    function _getCurrentMinMaxAmounts() internal view returns(uint256 minGear, uint256 maxGear, uint256 minEth, uint256 maxEth) {
        minGear = totalGearCommitted <= gearMinAmount ? gearMinAmount : totalGearCommitted;
        maxGear = stage > Stage.GEAR_DEPOSIT ? totalGearCommitted : gearMaxAmount;

        minEth = totalEthCommitted <= ethMinAmount ? ethMinAmount : totalEthCommitted;
        maxEth = stage > Stage.ETH_DEPOSIT ? totalEthCommitted : ethMaxAmount;
    }

    // Returns ETH / GEAR price range
    function getPriceRangeEthGear() external view returns (uint256 minPrice, uint256 maxPrice) {

        (uint256 minGear, uint256 maxGear, uint256 minEth, uint256 maxEth) = _getCurrentMinMaxAmounts();

        minPrice = minEth * PRICE_MULTIPLIER / maxGear;
        maxPrice = maxEth * PRICE_MULTIPLIER / minGear;
    }

    // Returns GEAR / ETH price range
    function getPriceRangeGearEth() external view returns (uint256 minPrice, uint256 maxPrice) {

        (uint256 minGear, uint256 maxGear, uint256 minEth, uint256 maxEth) = _getCurrentMinMaxAmounts();

        minPrice = minGear * PRICE_MULTIPLIER / maxEth;
        maxPrice = maxGear * PRICE_MULTIPLIER / minEth;
    }

    function getPendingLPAmount() public view returns (uint256 lpAmount) {
       lpAmount = gearCommitted[msg.sender] * totalLPTokens / (2 * totalGearCommitted) + 
                           ethCommitted[msg.sender] * totalLPTokens / (2 * totalEthCommitted);
    }

    function getTimeUntilLPClaim() external view returns (uint256 lpAmount) {
        return fairTradingEnd > block.timestamp ? fairTradingEnd - block.timestamp : 0;
    }

}
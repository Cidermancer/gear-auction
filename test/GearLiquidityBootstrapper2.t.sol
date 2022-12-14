// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GearLiquidityBootstrapper} from "../src/GearLiquidityBootstrapper.sol";
import {GearLiquidityBootstrapper2} from "../src/GearLiquidityBootstrapper2.sol";
import {IGearToken} from "../src/interfaces/IGearToken.sol";
import {ICurvePool} from "../src/interfaces/ICurvePool.sol";
import "../src/constants2.sol";

uint256 constant FAIR_TRADING_SELL_SIZE = 1_000_000 * 10 ** 18;
address constant GEAR_DEPOSITOR = 0x84641137BaC4Db68DE94Ec3D2ED89acE0AA88f20;

contract GearLiquidityBootstrapperTest is Test {
    GearLiquidityBootstrapper2 public glb;
    IGearToken public gearToken;

    function setUp() public {

        gearToken = IGearToken(GEAR_TOKEN);

        vm.prank(DUMMY);
        glb = new GearLiquidityBootstrapper2();
    }

    function _inheritGLB1() internal {

        vm.prank(GEARBOX_TREASURY);
        GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).fail();

        vm.prank(GEARBOX_TREASURY);
        GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).takeGEARManagerBack();

        vm.prank(GEARBOX_TREASURY);
        GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).execute(
            address(gearToken),
            abi.encodeWithSelector(
                IERC20.approve.selector,
                address(glb),
                type(uint256).max
            )
        );

        vm.prank(GEARBOX_TREASURY);
        gearToken.transferOwnership(address(glb));

        vm.prank(GEARBOX_TREASURY);
        glb.inheritGLB1();
    }

    function _fastForwardEthDeposit() internal {
        _inheritGLB1();

        vm.warp(glb.ethDepositStart());
    }

    function _fastForwardFairTrading() internal {
        _fastForwardEthDeposit();

        uint256 minAmount = glb.ethMinAmount();

        deal(DUMMY, minAmount / 2);

        vm.prank(DUMMY);
        glb.commitETH{value: minAmount / 2}();

        deal(DUMMY2, minAmount / 2);

        vm.prank(DUMMY2);
        glb.commitETH{value: minAmount / 2}();

        vm.warp(glb.fairTradingStart());
    }

    function _fastForwardFinished() internal {
        _fastForwardFairTrading();

        glb.advanceStage();

        deal(address(gearToken), DUMMY, FAIR_TRADING_SELL_SIZE);

        vm.prank(DUMMY);
        gearToken.approve(address(glb), FAIR_TRADING_SELL_SIZE);

        vm.prank(DUMMY);
        glb.sellGEAR(FAIR_TRADING_SELL_SIZE, 0);

        vm.warp(glb.fairTradingEnd());
    }

    function test_2_01_initialParams() public {

        assertEq(
            address(glb.gear()),
            GEAR_TOKEN,
            "Gear token set incorrectly"
        );

        assertEq(
            glb.weth(),
            WETH20,
            "WETH set incorrectly"
        );

        assertEq(
            address(glb.curveFactory()),
            CURVE_FACTORY,
            "Curve factory set incorrectly"
        );

        assertEq(
            glb.ethMaxAmount(),
            ETH_MAX_AMOUNT,
            "ETH max amount incorrect"
        );

        assertEq(
            glb.ethMinAmount(),
            ETH_MIN_AMOUNT,
            "ETH min amount incorrect"
        );

        assertEq(
            glb.fairTradingStart(),
            ETH_DEPOSIT_START + ETH_DEPOSIT_DURATION,
            "Fair trading start incorrect"
        );

        assertEq(
            glb.fairTradingEnd(),
            ETH_DEPOSIT_START + ETH_DEPOSIT_DURATION + FAIR_TRADING_DURATION,
            "Fair trading end incorrect"
        );

        assertEq(
            glb.shearingPctStart(),
            STARTING_SHEARING_PCT,
            "Starting shearing pct incorrect"
        );

        assertEq(
            glb.curvePool_A(),
            DEFAULT_A,
            "Curve pool A incorrect"
        );

        assertEq(
            glb.curvePool_gamma(),
            DEFAULT_GAMMA,
            "Curve pool gamma incorrect"
        );

        assertEq(
            glb.curvePool_mid_fee(),
            DEFAULT_MID_FEE,
            "Curve pool mid_fee incorrect"
        );

        assertEq(
            glb.curvePool_out_fee(),
            DEFAULT_OUT_FEE,
            "Curve pool out_fee incorrect"
        );

        assertEq(
            glb.curvePool_allowed_extra_profit(),
            DEFAULT_ALLOWED_EXTRA_PROFIT,
            "Curve pool allowed_extra_profit incorrect"
        );

        assertEq(
            glb.curvePool_fee_gamma(),
            DEFAULT_FEE_GAMMA,
            "Curve pool fee_gamma incorrect"
        );

        assertEq(
            glb.curvePool_adjustment_step(),
            DEFAULT_ADJUSTMENT_STEP,
            "Curve pool adjustment_step incorrect"
        );

        assertEq(
            glb.curvePool_admin_fee(),
            DEFAULT_ADMIN_FEE,
            "Curve pool admin_fee incorrect"
        );

        assertEq(
            glb.curvePool_ma_half_time(),
            DEFAULT_MA_HALF_TIME,
            "Curve pool ma_half_time incorrect"
        );
    }

    function test_2_02_setGearMiner() public {
        _inheritGLB1();

        vm.expectRevert("Ownable: caller is not the owner");
        glb.setGearMiner(DUMMY);

        vm.prank(GEARBOX_TREASURY);
        glb.setGearMiner(DUMMY);

        assertEq(
            gearToken.miner(),
            DUMMY,
            "Gear miner is incorrect"
        );
    }

    function test_2_03_fail() public {
        vm.expectRevert("Ownable: caller is not the owner");
        glb.fail();

        vm.prank(GEARBOX_TREASURY);
        glb.fail();

        assertEq(
            uint8(glb.stage()),
            5,
            "Stage is not FAILED"
        );
    }

    function test_2_04_execute() public {
        _inheritGLB1();

        bytes memory callData = abi.encodeWithSignature(
            "approve(address,uint256)",
            DUMMY,
            100
        );

        vm.expectRevert("Ownable: caller is not the owner");
        glb.execute(address(gearToken), callData);

        vm.expectCall(
            address(gearToken),
            callData
        );

        vm.prank(GEARBOX_TREASURY);
        glb.execute(address(gearToken), callData);

        assertEq(
            gearToken.allowance(address(glb), DUMMY),
            100,
            "Action was not executed"
        );
    }

    function test_2_05_inheritGLB1() public {

        uint256 gearRemainder = gearToken.balanceOf(GEAR_LIQUIDITY_BOOTSTRAPPER_1);

        vm.prank(GEARBOX_TREASURY);
        GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).fail();

        vm.prank(GEARBOX_TREASURY);
        GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).takeGEARManagerBack();

        vm.prank(GEARBOX_TREASURY);
        GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).execute(
            address(gearToken),
            abi.encodeWithSelector(
                IERC20.approve.selector,
                address(glb),
                type(uint256).max
            )
        );

        vm.prank(GEARBOX_TREASURY);
        gearToken.transferOwnership(address(glb));

        vm.prank(GEARBOX_TREASURY);
        glb.inheritGLB1();

        assertEq(
            gearToken.balanceOf(address(glb)),
            gearRemainder,
            "Incorrect GEAR amount transferred"
        );

        assertEq(
            glb.totalGearCommitted(),
            gearRemainder,
            "Incorrect total GEAR committed"
        );
    }

    function test_2_07_commitETH() public {

        uint256 maxAmount = glb.ethMaxAmount();

        deal(DUMMY, maxAmount/ 2);

        vm.expectRevert("Can't be called during the current stage");
        vm.prank(DUMMY);
        glb.commitETH{value: maxAmount / 4}();

        _fastForwardEthDeposit();

        assertEq(
            uint8(glb.stage()),
            0,
            "Stage must be INITIALIZED"
        );

        vm.prank(DUMMY);
        glb.commitETH{value: maxAmount / 4}();

        assertEq(
            uint8(glb.stage()),
            2,
            "ETH deposit stage not set"
        );

        assertEq(
            glb.totalEthCommitted(),
            maxAmount / 4,
            "Incorrect total committed"
        );

        assertEq(
            glb.ethCommitted(DUMMY),
            maxAmount / 4,
            "Incorrect committed by user"
        );

        assertEq(
            payable(address(glb)).balance,
            maxAmount / 4,
            "Incorrect contract ETH balance"
        );

        vm.prank(DUMMY);
        (, bytes memory res) = payable(address(glb)).call{value: maxAmount / 4}("");

        assertEq(
            glb.totalEthCommitted(),
            maxAmount / 2,
            "Incorrect total committed"
        );

        assertEq(
            glb.ethCommitted(DUMMY),
            maxAmount / 2,
            "Incorrect committed by user"
        );

        assertEq(
            payable(address(glb)).balance,
            maxAmount / 2,
            "Incorrect contract ETH balance"
        );

        deal(DUMMY2, maxAmount * 3 / 4);

        vm.prank(DUMMY2);
        (, res) = payable(address(glb)).call{value: maxAmount * 3 / 4}("");

        assertEq(
            glb.totalEthCommitted(),
            maxAmount,
            "Incorrect total committed"
        );

        assertEq(
            glb.ethCommitted(DUMMY2),
            maxAmount / 2,
            "Incorrect committed by user"
        );

        assertEq(
            payable(address(glb)).balance,
            maxAmount,
            "Incorrect contract ETH balance"
        );

        assertEq(
            payable(DUMMY2).balance,
            maxAmount / 4,
            "Incorrect amount returned to sender"
        );

        vm.expectRevert("Nothing to commit");
        vm.prank(DUMMY2);
        (, res) = payable(address(glb)).call{value: maxAmount / 4}("");
    }

    function test_2_08_advanceStage_to_EthDeposit() public {
        _fastForwardEthDeposit();

        vm.warp(block.timestamp - 1);

        glb.advanceStage();

        assertEq(
            uint8(glb.stage()),
            0,
            "Stage must not be advanced yet"
        );

        vm.warp(block.timestamp + 1);

        glb.advanceStage();

        assertEq(
            uint8(glb.stage()),
            2,
            "Stage must be ETH deposit"
        );
    }

    function test_2_09B_advanceStage_to_failed() public {
        _fastForwardEthDeposit();

        vm.warp(glb.fairTradingStart());

        assertEq(
            uint8(glb.stage()),
            0,
            "Stage must be GEAR deposit"
        );

        glb.advanceStage();

        assertEq(
            uint8(glb.stage()),
            5,
            "Stage was not advanced to failed"
        );
    }

    function test_2_09D_advanceStage_to_failed() public {
        _fastForwardEthDeposit();

        uint256 maxAmount = glb.ethMaxAmount();

        deal(DUMMY, maxAmount / 2);

        vm.prank(DUMMY);
        glb.commitETH{value: maxAmount / 2}();

        vm.warp(glb.fairTradingStart());

        assertEq(
            uint8(glb.stage()),
            2,
            "Stage must be ETH deposit"
        );

        glb.advanceStage();

        assertEq(
            uint8(glb.stage()),
            5,
            "Stage was not advanced to failed"
        );
    }

    function test_2_10_deployPool() public {
        _fastForwardFairTrading();

        glb.advanceStage();

        ICurvePool pool = glb.curvePool();

        assertEq(
            gearToken.balanceOf(address(pool)),
            glb.totalGearCommitted(),
            "Incorrect GEAR added to pool"
        );

        assertEq(
            payable(address(pool)).balance,
            glb.totalEthCommitted(),
            "Incorrect ETH added to pool"
        );

        assertGt(
            IERC20(pool.token()).balanceOf(address(glb)),
            0,
            "LP token was not sent to controller"
        );

        assertApproxEqRel(
            pool.get_dy(1, 0, 10 ** 18),
            glb.totalGearCommitted() * 10 ** 18 / glb.totalEthCommitted(),
            3 * 10 ** 18 / 1000,
            "dy difference between pool and GLB > fee"
        );
    }

    function test_2_11_sellGEAR() public {

        _fastForwardFairTrading();

        vm.warp(block.timestamp - 1);

        vm.expectRevert("Can't be called during the current stage");
        glb.sellGEAR(10 ** 18, 0);

        vm.warp(block.timestamp + 1);

        glb.advanceStage();

        uint256 swappedAmount = 100000 * 10 ** 18;

        deal(address(gearToken), DUMMY, swappedAmount);

        vm.prank(DUMMY);
        gearToken.approve(address(glb), swappedAmount);

        uint256 expectedCurrentShear = STARTING_SHEARING_PCT;

        uint256 sheared = expectedCurrentShear * swappedAmount / 10 ** 18;

        uint256 sold = swappedAmount - sheared;

        uint256 expectedETHAmount = glb.curvePool().get_dy(0, 1, sold);

        vm.prank(DUMMY);
        glb.sellGEAR(swappedAmount, expectedETHAmount / 2);

        assertEq(
            gearToken.balanceOf(address(glb)),
            sheared,
            "Incorrect amount sheared"
        );

        assertEq(
            payable(DUMMY).balance,
            expectedETHAmount,
            "Incorrect ETH amount sent to user"
        );

        vm.warp((glb.fairTradingStart() + glb.fairTradingEnd()) / 2);

        deal(address(gearToken), DUMMY2, swappedAmount);

        vm.prank(DUMMY2);
        gearToken.approve(address(glb), swappedAmount);

        expectedCurrentShear = STARTING_SHEARING_PCT / 2;

        sheared = expectedCurrentShear * swappedAmount / 10 ** 18;

        sold = swappedAmount - sheared;

        expectedETHAmount = glb.curvePool().get_dy(0, 1, sold);

        vm.prank(DUMMY2);
        glb.sellGEAR(swappedAmount, expectedETHAmount / 2);

        assertEq(
            gearToken.balanceOf(address(glb)),
            sheared * 3,
            "Incorrect amount sheared"
        );

        assertEq(
            payable(DUMMY2).balance,
            expectedETHAmount,
            "Incorrect ETH amount sent to user"
        );
    }

    function test_2_12_buyGEAR() public {
        _fastForwardFairTrading();

        vm.warp(block.timestamp - 1);

        vm.expectRevert("Can't be called during the current stage");
        glb.buyGEAR(0);

        vm.warp(block.timestamp + 1);

        glb.advanceStage();

        deal(DUMMY, 10 ** 18);

        uint256 expectedGEARBack = glb.curvePool().get_dy(1, 0, 10 ** 18);

        vm.prank(DUMMY);
        glb.buyGEAR{value: 10 ** 18}(expectedGEARBack);

        assertEq(
            gearToken.balanceOf(DUMMY),
            expectedGEARBack,
            "Incorrect GEAR returned to buyer"
        );
    }

    function test_2_13_advanceStage_to_finished() public {
        _fastForwardFairTrading();

        vm.warp(glb.fairTradingEnd() - 1);

        glb.advanceStage();

        assertEq(
            uint8(glb.stage()),
            3,
            "Stage must not be advanced yet"
        );

        vm.warp(block.timestamp + 1);

        glb.advanceStage();

        assertEq(
            uint8(glb.stage()),
            4,
            "Stage must be FINISHED"
        );

        assertTrue(
            gearToken.transfersAllowed(),
            "GEAR transfers were not allowed on finishing"
        );

        assertEq(
            gearToken.miner(),
            address(gearToken),
            "GEAR miner was not set"
        );

        assertEq(
            gearToken.manager(),
            address(gearToken),
            "GEAR manager was not set"
        );
    }

    function test_2_14_claimLP() public {

        vm.expectRevert("Can't be called during the current stage");
        glb.claimLP();

        _fastForwardFinished();

        uint256 expectedLP = (glb.totalLPTokens() * glb.gearCommitted(DUMMY)) / (2 * glb.totalGearCommitted());
        expectedLP += (glb.totalLPTokens() * glb.ethCommitted(DUMMY)) / (2 * glb.totalEthCommitted());

        vm.prank(DUMMY);
        glb.claimLP();

        assertEq(
            IERC20(glb.curvePool().token()).balanceOf(DUMMY),
            expectedLP,
            "Incorrect LP amount sent to user 1"
        );

        expectedLP = (glb.totalLPTokens() * glb.gearCommitted(DUMMY2)) / (2 * glb.totalGearCommitted());
        expectedLP += (glb.totalLPTokens() * glb.ethCommitted(DUMMY2)) / (2 * glb.totalEthCommitted());

        vm.prank(DUMMY2);
        glb.claimLP();

        assertEq(
            IERC20(glb.curvePool().token()).balanceOf(DUMMY2),
            expectedLP,
            "Incorrect LP amount sent to user 2"
        );

    }

    function test_2_15_retrieveShearedGear() public {

        uint256 initialBalance = gearToken.balanceOf(GEARBOX_TREASURY);

        vm.expectRevert("Can't be called during the current stage");
        glb.retrieveShearedGEAR();

        _fastForwardFinished();

        vm.expectRevert("Ownable: caller is not the owner");
        glb.retrieveShearedGEAR();

        vm.prank(GEARBOX_TREASURY);
        glb.retrieveShearedGEAR();

        assertEq(
            gearToken.balanceOf(address(glb)),
            0,
            "Not the entire balance was sent"
        );

        assertEq(
            gearToken.balanceOf(GEARBOX_TREASURY) - initialBalance,
            FAIR_TRADING_SELL_SIZE * STARTING_SHEARING_PCT / 10 ** 18,
            "Incorrect amount was sent"
        );
    }

    function test_2_16_retrieveGEAR_retrieveETH() public {
        _fastForwardEthDeposit();

        vm.expectRevert("Can't be called during the current stage");
        glb.retrieveGEAR();

        vm.expectRevert("Can't be called during the current stage");
        glb.retrieveETH();

        uint256 minAmount = glb.ethMinAmount();

        deal(DUMMY, minAmount / 2);

        vm.prank(DUMMY);
        glb.commitETH{value: minAmount / 2}();

        vm.warp(glb.fairTradingStart());

        uint256 gearAmount = GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).gearCommitted(GEAR_DEPOSITOR);

        glb.advanceStage();

        vm.prank(GEAR_DEPOSITOR);
        glb.retrieveGEAR();

        assertEq(
            gearToken.balanceOf(GEAR_DEPOSITOR),
            gearAmount,
            "Incorrect amount of GEAR returned to user 1"
        );

        vm.prank(DUMMY);
        glb.retrieveETH();

        assertEq(
            payable(DUMMY).balance,
            minAmount / 2,
            "Incorrect amount of ETH returned to user 1"
        );

    }

    function test_2_17_takeGEARManagerBack() public {
        _inheritGLB1();

        vm.expectRevert("Can't be called during the current stage");
        glb.takeGEARManagerBack();

        vm.prank(GEARBOX_TREASURY);
        glb.fail();

        vm.expectRevert("Ownable: caller is not the owner");
        glb.takeGEARManagerBack();

        vm.prank(GEARBOX_TREASURY);
        glb.takeGEARManagerBack();

        assertEq(
            gearToken.manager(),
            GEARBOX_TREASURY,
            "New owner is not correct"
        );

    }

    function test_2_18B_getPriceRange_EthGear() public {

        _fastForwardEthDeposit();

        (uint256 minPrice, uint256 maxPrice) = glb.getPriceRangeEthGear();

        assertEq(
            minPrice,
            glb.ethMinAmount() * 10 ** 18 / glb.totalGearCommitted(),
            "Incorrect min price"
        );

        assertEq(
            maxPrice,
            glb.ethMaxAmount() * 10 ** 18 / glb.totalGearCommitted(),
            "Incorrect max price"
        );
    }

    function test_2_18C_getPriceRange_EthGear() public {

        _fastForwardFairTrading();

        (uint256 minPrice, uint256 maxPrice) = glb.getPriceRangeEthGear();

        assertEq(
            minPrice,
            glb.ethMinAmount() * 10 ** 18 / glb.totalGearCommitted(),
            "Incorrect min price"
        );

        assertEq(
            maxPrice,
            glb.ethMinAmount() * 10 ** 18 / glb.totalGearCommitted(),
            "Incorrect max price"
        );
    }

    function test_2_19B_getPriceRange_GearEth() public {

        _fastForwardEthDeposit();

        (uint256 minPrice, uint256 maxPrice) = glb.getPriceRangeGearEth();

        assertEq(
            minPrice,
            glb.totalGearCommitted() * 10 ** 18 / glb.ethMaxAmount(),
            "Incorrect min price"
        );

        assertEq(
            maxPrice,
            glb.totalGearCommitted() * 10 ** 18 / glb.ethMinAmount(),
            "Incorrect max price"
        );
    }

    function test_2_19C_getPriceRange_GearEth() public {

        _fastForwardFairTrading();

        (uint256 minPrice, uint256 maxPrice) = glb.getPriceRangeGearEth();

        assertEq(
            minPrice,
            glb.totalGearCommitted() * 10 ** 18 / glb.ethMinAmount(),
            "Incorrect min price"
        );

        assertEq(
            maxPrice,
            glb.totalGearCommitted() * 10 ** 18 / glb.ethMinAmount(),
            "Incorrect max price"
        );
    }

    function test_2_20_getPendingLPAmount() public {
        _fastForwardFairTrading();

        glb.advanceStage();

        uint256 gearAmount = GearLiquidityBootstrapper(payable(GEAR_LIQUIDITY_BOOTSTRAPPER_1)).gearCommitted(GEAR_DEPOSITOR);

        uint256 expectedLP = (glb.totalLPTokens() * gearAmount) / (2 * glb.totalGearCommitted());

        vm.prank(GEAR_DEPOSITOR);
        uint256 lpAmount = glb.getPendingLPAmount();

        assertEq(
            lpAmount,
            expectedLP,
            "LP amount was not computed correctly"
        );

        expectedLP = (glb.totalLPTokens() * glb.ethMinAmount() / 2) / (2 * glb.ethMinAmount());

        vm.prank(DUMMY);
        lpAmount = glb.getPendingLPAmount();

        assertEq(
            lpAmount,
            expectedLP,
            "LP amount was not computed correctly"
        );
    }

    function test_2_21_getTimeUntilLPClaim() public {

        vm.warp(glb.ethDepositStart());

        uint256 time = glb.getTimeUntilLPClaim();

        assertEq(
            time,
            glb.fairTradingEnd() - glb.ethDepositStart()
        );


    }

    function test_2_22_fairTrading_getters() public {
        _fastForwardFairTrading();

        glb.advanceStage();

        uint256 swappedAmount = 100000 * 10 ** 18;

        uint256 expectedCurrentShear = STARTING_SHEARING_PCT;

        uint256 sheared = expectedCurrentShear * swappedAmount / 10 ** 18;

        uint256 sold = swappedAmount - sheared;

        uint256 expectedETHAmount = glb.curvePool().get_dy(0, 1, sold);

        assertEq(
            glb.getCurrentShearingPct(),
            expectedCurrentShear,
            "Incorrect shearing pct"
        );

        assertEq(
            glb.getETHFromGEARAmount(swappedAmount),
            expectedETHAmount,
            "Incorrect ETH amount retrieved"
        );

        vm.warp((glb.fairTradingStart() + glb.fairTradingEnd()) / 2);

        expectedCurrentShear = STARTING_SHEARING_PCT / 2;

        sheared = expectedCurrentShear * swappedAmount / 10 ** 18;

        sold = swappedAmount - sheared;

        expectedETHAmount = glb.curvePool().get_dy(0, 1, sold);

        assertEq(
            glb.getCurrentShearingPct(),
            expectedCurrentShear,
            "Incorrect shearing pct"
        );

        assertEq(
            glb.getETHFromGEARAmount(swappedAmount),
            expectedETHAmount,
            "Incorrect ETH amount retrieved"
        );

        uint256 swappedETHAmount = 10 ** 18;

        uint256 expectedGEARAmount = glb.curvePool().get_dy(1, 0, swappedETHAmount);

        assertEq(
            glb.getGEARFromETHAmount(swappedETHAmount),
            expectedGEARAmount,
            "Incorrect GEAR amount retrieved"
        );
    }
}

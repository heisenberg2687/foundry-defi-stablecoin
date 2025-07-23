// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DesentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {Test} from "lib/forge-std/src/Test.sol";
import {console} from "lib/forge-std/src/console.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/mockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethusdpricefeed;
    address weth;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 1e18; // 1 ETH
    uint256 public constant AMOUNT_TO_MINT = 500e18; // Mint $500 DSC
    uint256 public constant AMOUNT_TO_BURN = 500e18; // Burn all minted DSC
    uint256 public constant STARTING_ERC20_BALANCE = 2e18; // Enough for testing
    uint256 public constant DEBT_TO_COVER = 500e18; // $500 DSC

    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1e18 is the precision, so if the health factor is less than 1e18, then they are undercollateralized.
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized or only half of the collateral value is mint to DSC
    uint256 private constant LIQUIDATION_PRECISION = 100; // as a percentage, so 50% is 50/100, 200% is 200/100, etc.
    uint256 private constant LIQUIDATION_BONUS = 10;

    function setUp() public {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dsce, config) = deployDSC.run();
        (ethusdpricefeed,, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE + 100e18); // Extra for liquidation tests
    }

    ////////////////////////
    // Constructor Tests ///
    ////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesNotMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethusdpricefeed);
        // Add an extra address to the price feed addresses
        priceFeedAddresses.push(ethusdpricefeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////
    function testGetUsdValueFromTokenAmount() public view {
        uint256 ethAmount = 15e18; // 15 ether
        uint256 expectedUsdValue = 30000e18; //15e18 * 2000e8 / 1e8
        uint256 actualUsdValue = dsce.getUsdValueFromTokenAmount(weth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    function testGetTokenAmountFromUsdValue() public view {
        uint256 usdValue = 30000e18; // 30,000 USD
        uint256 expectedEthAmount = 15e18; // 15 ETH
        uint256 actualEthAmount = dsce.getTokenAmountFromUsdValue(weth, usdValue);
        assertEq(actualEthAmount, expectedEthAmount);
    }

    //////////////////////////////
    // Collateral deposit Tests //
    //////////////////////////////
    function testdepositCollateralPass() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfCollateralIsNotApproved() public {
        ERC20Mock chuToken = new ERC20Mock("CHU", "CHU", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(chuToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        _;
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 collateralValueInUsd, uint256 totalDscMinted) = dsce.getAccountInformation(USER);

        uint256 expectedCollateralValueInUsd = dsce.getUsdValueFromTokenAmount(weth, AMOUNT_COLLATERAL);
        uint256 expectedtotalDscMinted = 0;
        uint256 expectedDepositedCollateral = dsce.getTokenAmountFromUsdValue(weth, expectedCollateralValueInUsd);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
        assertEq(totalDscMinted, expectedtotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedCollateral);
    }

    function testDepositEmitsCorrectEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true);
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL); // this emits the event

        vm.stopPrank();
    }

    //////////////////////////////
    // Minting dsc Tests /////////
    //////////////////////////////
    function testRevertsIfMintedDscIsZero() public depositedCollateral {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
    }

    function testRevertsIfMintingDscBreaksHealthFactor() public depositedCollateral {
        uint256 dscToMint = 1100e18;
        uint256 collateralValueInUsd = dsce.getUsdValueFromTokenAmount(weth, AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(dscToMint, collateralValueInUsd);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(dscToMint);
    }

    function testMintDscEmitsEvent() public depositedCollateral {
        uint256 dscToMint = 100;

        vm.expectEmit(true, true, true, true);
        emit DSCEngine.DscMinted(USER, dscToMint);
        dsce.mintDsc(dscToMint);
    }

    //////////////////////////////
    //  depositAndMint Tests    //
    //////////////////////////////
    function testDepositCollateralAndMintDscPassExactValues() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 dscToMint = 100;
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, dscToMint);

        // Check updated values
        (uint256 collateralValue, uint256 dscMinted) = dsce.getAccountInformation(USER);
        assertEq(collateralValue, dsce.getUsdValueFromTokenAmount(weth, AMOUNT_COLLATERAL));
        assertEq(dscMinted, dscToMint);
        vm.stopPrank();
    }

    function testRevertsIfDepositCollateralAndMintDscBreaksHealthFactor() public {
        vm.startPrank(USER);

        // Approve WETH to DSCEngine (max for safety)
        ERC20Mock(weth).approve(address(dsce), type(uint256).max);

        uint256 dscToMint = 1100e18;
        uint256 collateralValueInUsd = dsce.getUsdValueFromTokenAmount(weth, AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(dscToMint, collateralValueInUsd);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));

        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, dscToMint);

        vm.stopPrank();
    }

    function testDepositCollateralAndMintDscEmitsCorrectEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 dscToMint = 100;

        vm.expectEmit(true, true, true, true);
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, true);
        emit DSCEngine.DscMinted(USER, dscToMint);

        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, dscToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        _;
        vm.stopPrank();
    }

    //////////////////////////////
    // redeemcollateral Tests   //
    //////////////////////////////
    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        uint256 userBalanceBeforeRedeem = dsce.getAccountCollateralValue(USER);
        assertEq(userBalanceBeforeRedeem, dsce.getUsdValueFromTokenAmount(weth, AMOUNT_COLLATERAL));
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalanceAfterRedeem = dsce.getAccountCollateralValue(USER);
        assertEq(userBalanceAfterRedeem, 0);
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true); // All indexed args set to true
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
    }

    /////////////////////////
    //// burnDSC Tests   ////
    /////////////////////////
    function testRevertsIfBurnAmountIsZero() public depositedCollateralAndMintedDsc {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        uint256 dscBalanceBeforeBurn = dsc.balanceOf(USER);
        assertEq(dscBalanceBeforeBurn, AMOUNT_TO_MINT);
        dsc.approve(address(dsce), AMOUNT_TO_MINT);
        dsce.burnDsc(AMOUNT_TO_BURN);
        uint256 dscBalanceAfterBurn = dsc.balanceOf(USER);
        assertEq(dscBalanceAfterBurn, 0);
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    //////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////
    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        dsc.approve(address(dsce), AMOUNT_TO_BURN);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, AMOUNT_TO_BURN);
    }

    function testCanRedeemDepositedCollateralAndBurnDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        dsc.approve(address(dsce), AMOUNT_TO_BURN);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_BURN);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 2 ether;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        // $500 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $1000 collatareral at all times.
        // 2,000 * 0.5 = 1,000
        // 1,000 / 500 = 2 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 800e8; // 1 ETH = $800
        // Remember, we need $1000 at all times if we have $500 of debt

        MockV3Aggregator(ethusdpricefeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        // 800*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 400 / 500 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.8 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////
    function testCanLiquidateUndercollateralizedPosition() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        // Update the price feed to make the position undercollateralized
        int256 ethUsdUpdatedPrice = 800e8; // 1 ETH = $800
        MockV3Aggregator(ethusdpricefeed).updateAnswer(ethUsdUpdatedPrice);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL + 100e18);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL + 100e18, AMOUNT_TO_MINT);

        // Approve the DSCEngine to spend the liquidator's Dsc
        dsc.approve(address(dsce), DEBT_TO_COVER);

        // Liquidate the user's position
        dsce.liquidate(weth, USER, DEBT_TO_COVER);

        vm.stopPrank();
    }

    // function testRevertsIfHealthFactorIsOk() public {
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
    //     vm.stopPrank();

    //     // Do NOT reduce price → health factor remains > 1

    //     vm.startPrank(LIQUIDATOR);
    //     ERC20Mock(weth).approve(address(dsce), 2e18);
    //     dsce.depositCollateralAndMintDsc(weth, 2e18, DEBT_TO_COVER);
    //     dsc.approve(address(dsce), DEBT_TO_COVER);

    //     // Expect revert because user is healthy
    //     vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
    //     dsce.liquidate(weth, USER, DEBT_TO_COVER);

    //     vm.stopPrank();
    // }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethusdpricefeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    // function testGetAccountCollateralValueFromInformation() public depositedCollateral {
    //     (, uint256 collateralValue) = dsce.getAccountInformation(USER);
    //     uint256 expectedCollateralValue = dsce.getUsdValueFromTokenAmount(weth, AMOUNT_COLLATERAL);
    //     assertEq(collateralValue, expectedCollateralValue);
    // }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    // function testGetAccountCollateralValue() public {                     // not working check kr lio baad mai
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
    //     vm.stopPrank();
    //     uint256 collateralValue = dsce.getAccountCollateralValue(USER);
    //     uint256 expectedCollateralValue = dsce.getUsdValueFromTokenAmount(weth, AMOUNT_COLLATERAL);
    //     assertEq(collateralValue, expectedCollateralValue);
    // }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}

// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volatility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DesentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries.sol";

/**
 * @title DSCEngine
 * @author heisenberg2687
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * this stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - ALgorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by wETH and wBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contarct is the core of the DSC system. It handeles all the logic for mining and redeeming DSC, as well as depositing & wuthdrawing collateral.
 * @notice this contarct is very loosely based on the MakedDAO DAS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////
    //  ERRORS    //
    ////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSame();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;
    error OracleLib__StalePrice();


    ////////////////////////
    //  STATE VARIABLE    //
    ////////////////////////
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1e18 is the precision, so if the health factor is less than 1e18, then they are undercollateralized.
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized or only half of the collateral value is mint to DSC
    uint256 private constant LIQUIDATION_PRECISION = 100; // as a percentage, so 50% is 50/100, 200% is 200/100, etc.
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address pricefeed) private s_pricefeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposits;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    //   Events   //
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event DscMinted(address indexed user, uint256 indexed DscMinted);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed RedeemedTo, address indexed token, uint256 amount
    );

    /////////////////
    //  MODIFIERS  //
    /////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_pricefeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////
    //  FUNCTIONS  //
    /////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSame();
        }
        // For example ETH/USD, BTC/USD, etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_pricefeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    //  EXTERNAL FUNCTIONS  //
    //////////////////////////

    /**
     * @notice This function deposits collateral and mints DSC in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token to deposit
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     *
     * @dev This function follows the Checks-Effects-Interactions (CEI) pattern.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the collateral token to deposit
     * @param amountCollateral The amount of collateral to deposit
     *
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposits[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice This function redeems collateral for DSC. It burns the DSC and then redeems the collateral in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks the health factor, so we don't need to check it again here.
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // this method will check before redeeming collateral that the health factor is not broken. but patric used different method for reuesibility
        // uint256 collateralValueInUsdToRedeem = getUsdValueFromTokenAmount(tokenCollateralAddress, amountCollateral);
        // uint256 remainingCollateralValueInUsd = getAccountCollateralValue(msg.sender) - collateralValueInUsdToRedeem;
        // uint256 mintedDsc = s_DscMinted[msg.sender];
        // uint256 healthFactor = _calculateHealthFactor(mintedDsc, remainingCollateralValueInUsd);

        // if (healthFactor < MIN_HEALTH_FACTOR) {
        //     revert DSCEngine__BreaksHealthFactor(healthFactor);
        // }
        // _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

        // this methods doesnt follow the CEI pattern, but it is more reusable and allows for more flexibility.
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI pattern
     * @param amountDscToMint The amount of DSC to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        // if they minted too much (150$ DSC but only have 100$ collateral)
        _revertIfHealthFactorIsBroken(msg.sender);
        emit DscMinted(msg.sender, amountDscToMint);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        // we have to approve  the DSC that we are gonna mint from user address for the DSCEngine contract address
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //this will never revert, because the user is burning DSC, which means they are reducing their debt but just in case
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 200% overcollateralized in order for this
     * to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
     * anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     *
     * We are not following CEI here.
     **/
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //  need to Check the health factor of the user
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= PRECISION) {
            revert DSCEngine__HealthFactorOK();
        }
        // we want to brun their DSC "debt"
        // And take theri collateral
        // Bad USer: 140$ ETH, 100$ DSC
        // debt to cover: 100$ DSC
        // 100$ of DSC == ?? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsdValue(collateral, debtToCover);
        // And give them a liquidation bonus(10%)
        // So we are giving the liquidator 110$ worth of collateral for 100$ of DSC
        // we should implement a feature to liquidate in the event the protocal is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // 10% bonus
        uint256 totalCollateralToTake = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToTake, user, msg.sender);
        // we need to burn the DSC from the user
        _burnDsc(debtToCover, user, msg.sender);

        uint256 userEndingHealthFactor = _healthFactor(user);
        if (userEndingHealthFactor <= userStartingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////////////
    //  Private & Internal View FUNCTIONS  //
    /////////////////////////////////////////

    /*
    * @dev Low-level internal function, do not call unless the function callining it is
    * checking for the health factor.(we dont check in internal functions. u have to check in the external function where u r using this function)
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        //this condition is not necessary, but it is good practice to check for transfer success
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposits[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalCollateralValueInUsd, uint256 totalDscMintedValue)
    {
        totalDscMintedValue = s_DscMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
        return (totalCollateralValueInUsd, totalDscMintedValue);
    }

    /**
     * @dev Returns how close the user is to being liquidated.
     * @dev If the health factor is less than 1, then they are undercollateralized. and thet can be liquidated.
     */
    function _healthFactor(address user) internal view returns (uint256) {
        (uint256 totalCollateralValueInUsd, uint256 totalDscMintedValue) = _getAccountInformation(user);
        uint256 healthFactor = _calculateHealthFactor(totalDscMintedValue, totalCollateralValueInUsd);
        return healthFactor;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            // 1e18 is the MIN_HEALTH_FACTOR, so if the health factor is less than 1e18, then they are undercollateralized.
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //////////////////////////////////////////
    //  Public and External View FUNCTIONS  //
    //////////////////////////////////////////

    function getTokenAmountFromUsdValue(address token, uint256 usdValue) public view returns (uint256 tokenAmount) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_pricefeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = $1000
        // The returned value from Chainlink is in 8 decimals, so we need to convert it to 18 decimals
        return (usdValue * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it
        // to the price of the token, and add it to the total collateral value.
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposits[user][token];
            totalCollateralValueInUsd += getUsdValueFromTokenAmount(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValueFromTokenAmount(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_pricefeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = $1000
        // The returned value from Chainlink is in 8 decimals, so we need to convert it to 18 decimals
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // Convert to 18 decimals
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalCollateralValueInUsd, uint256 totalDscMintedValue)
    {
        (totalCollateralValueInUsd, totalDscMintedValue) = _getAccountInformation(user);
        return (totalCollateralValueInUsd, totalDscMintedValue);
    }

    function getHealthFactor(address user) public view returns (uint256 healthFactor) {
        healthFactor = _healthFactor(user);
        return healthFactor;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256 healthFactor)
    {
        healthFactor = _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        return healthFactor;
    }

     function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposits[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_pricefeeds[token];
    }
}

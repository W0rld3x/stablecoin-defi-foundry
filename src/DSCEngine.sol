// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
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

import "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author W0rld3x
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == 1$ peg.
 *
 * This stablecoin has the properties:
 * -Exogenous Collateral
 * -Dollar Pegged
 * -Algoritmically Stable
 */

contract DSCEngine is ReentrancyGuard {
    // Errors

    error DESCEngine_NeedsMoreThanZero();
    error DESCEngine_TokenAddressesMustBeEqualToPriceFeedAddresses();
    error DESCEngine_TransferFailed();
    error DESCEngine_HealthFactorIsBelowMinimum();
    error DESCEngine_MintFailed();
    error DSCEngine_HealthFactorOK();
    error DSCEngine_HealthFactorNotImproved();
    error DSCEngine_NotAllowedToken();

    // error DESCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();

    //State variables

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_TRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; // Precision
    uint256 private constant MIN_HEALTH_FACTOR = 1; //
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus


    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_Dsc;

    // Events

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed userFrom, address indexed userTo, uint256 amount, address indexed collateralToken);

    // Modifiers

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DESCEngine_NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DESCEngine_TokenAddressesMustBeEqualToPriceFeedAddresses();
        }

        // For Example, BTC/USD, ETH/USD......
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }

        i_Dsc = DecentralizedStableCoin(dscAddress);
    }

    // Internal Functions
    /**
     * Returns how close to liquidation are you..
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC Minted
        // total collateral VALUE

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForTreshold = (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;

        // 1000 ETH * 50 = 50 000 / 100 = 500
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = (75 / 100) < 1

        return (collateralAdjustedForTreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        // 1. Check Health Factor (do they have enough collateral?)
        // 2. Revert if they dont
        uint256 useHealthFactor = _healthFactor(_user);
        if (useHealthFactor < MIN_HEALTH_FACTOR) {
            revert DESCEngine_HealthFactorIsBelowMinimum();
        }
    }

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[_user];
        collateralValueInUsd = getAccountCollateralValueInUsd(_user);
    }


    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {

        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, amountCollateral, tokenCollateralAddress);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DESCEngine_TransferFailed();

        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalOf, address dscFrom) private {

        s_DscMinted[onBehalOf] -= amountDscToBurn;
        bool success = i_Dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success){
            revert DESCEngine_TransferFailed();
        }

        i_Dsc.burn(amountDscToBurn);
    }




    // External Functions


    /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral 
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice this function will deposit your collateral and mint DSC in one transaction
    */

    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);

    }




    /*
    * @notice: Follow CEI (Check, Effects, Interaction)
    * @param: tokenCollateralAddress : The Address of the token to deposit as collateral
    * @param: amountCollateral : The Amount of collateral to deposit 
    */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DESCEngine_TransferFailed();
        }

        // _revertIfHealthFactorIsBroken(msg.sender);
    }


    /*
    * @param tokenCollateralAddress The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * This function burns DSC and redeems underlying collateral in one transaction
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks healthFactor

    }


    //in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    //DRY: Don't repeat yourself
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant() {
       
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);

    }




    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_Dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DESCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amountDsc) public moreThanZero(amountDsc) {
        _burnDsc(amountDsc, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...

    }

    //If we do start nearing undercollateralization, we need someone to liquidate positions

    //75$ backing 50$ DSC
    // Liquidator take 75$ backing and burns off the 50$ DSC
    //If someone is almost undercollateralized, we will pay you to liquidate them!


    /*
    * @param collateral The erc20 collateral address to liquidate from the user
    * @param user The user who has broken the health factor. Their _healthfactor should be below than MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to to burn to improve the users health factor
    * @notice You can partially liquidate a user.
    * @notice You will get a liquidation bonus for taking the users funds
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
    * @notice A know bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
    * For example if the price of the collateral plummeted before anyone could be liquidated.

    */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant() {

        // Need to check healthfactor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine_HealthFactorOK();
        }

        // We want to burn their DSC "debt"
        // And take their Collateral 
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // 100$ of DSC == ??? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent

        // 0.05 ETH * 1 = 0.005 ETH, 0.05
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral; 
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine_HealthFactorNotImproved();
        }

            _revertIfHealthFactorIsBroken(msg.sender);
    }




    function getHealthFactor() external view {}

    // Public & External view functions //

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        //get the USD value thanks to Chainlink Aggregator V3
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 2000$
        // The returned value will be 2000 * 1e8
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;


    }


    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        // price of ETH (token)
        // ?/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));

    }



    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
       
       (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

}

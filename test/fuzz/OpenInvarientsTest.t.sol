// // SPDX-License-Identifier: MIT

// // Have our invariants aka properties

// // What are our invariants?

// // 1. The total supply of DSC should be less than tha total value of the collateral

// // 2. Getter view functions should never revert <- evergreen invairent(all prorocals should have this invarient)

// pragma solidity ^0.8.18;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DesentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract InvareintsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig helperConfig;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, helperConfig) = deployer.run();
//         (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
//         // get the value of all the collateral in the protocol
//         // comapre it to all the debt(dsc total supply)

//         uint256 totalDscSupply = dsc.totalSupply();    // total debt
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint256 wethValue = dsce.getUsdValueFromTokenAmount(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValueFromTokenAmount(wbtc, totalWbtcDeposited);
//         uint256 totalCollateralValue = wethValue + wbtcValue;   // total value of collateral

//         assert(totalCollateralValue >= totalDscSupply);
//     }
// }

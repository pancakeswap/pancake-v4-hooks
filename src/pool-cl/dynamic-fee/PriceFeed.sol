// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract PriceFeed is IPriceFeed {
    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;

    AggregatorV3Interface public immutable oracle;

    constructor(address token0_, address token1_, address oracle_) {
        if (token0_ > token1_) {
            (token0_, token1_) = (token1_, token0_);
        }
        token0 = IERC20Metadata(token0_);
        token1 = IERC20Metadata(token1_);
        oracle = AggregatorV3Interface(oracle_);
    }

    /// @dev Override if the oracle base quote tokens do not match the order of
    /// token0 and token1, i.e., the price from oracle needs to be inversed, or
    /// if there is no corresponding oracle for token0 token1 pair so that
    /// combination of two oracles is required
    function getPriceX96() external view virtual returns (uint160 priceX96) {
        (, int256 answer,,,) = oracle.latestRoundData();
        priceX96 = uint160(FullMath.mulDiv(uint256(answer), FixedPoint96.Q96, 10 ** oracle.decimals()));
        priceX96 = uint160(FullMath.mulDiv(priceX96, token1.decimals(), token0.decimals()));
        // TODO: Is it better to cache the result?
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {CLBaseHook} from "../CLBaseHook.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET
} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {SD59x18, UNIT, convert, sub, mul, div, inv, exp, lt} from "prb-math/SD59x18.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract CLDynamicFeeHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    struct PoolInfo {
        IPriceFeed priceFeed;
        uint24 DFF_max; // in hundredth of bips
    }

    struct InitializeHookData {
        IPriceFeed priceFeed;
        uint24 DFF_max;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        ICLPoolManager.SwapParams params;
        bytes hookData;
    }

    mapping(PoolId id => PoolInfo poolInfo) public poolInfos;

    uint24 private _fee;
    bool private _isSim;

    error NotDynamicFeePool();
    error PriceFeedTokensNotMatch();
    error DFFMaxTooLarge();
    error DFFTooLarge();
    error SwapAndRevert(uint160 sqrtPriceX96);

    constructor(ICLPoolManager poolManager) CLBaseHook(poolManager) {}

    function getHooksRegistrationBitmap() external view override returns (uint16) {
        return uint16(1 << HOOKS_BEFORE_INITIALIZE_OFFSET | 1 << HOOKS_BEFORE_SWAP_OFFSET);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        if (!key.fee.isDynamicLPFee()) {
            revert NotDynamicFeePool();
        }

        InitializeHookData memory initializeHookData = abi.decode(hookData, (InitializeHookData));

        IPriceFeed priceFeed = IPriceFeed(initializeHookData.priceFeed);
        if (
            address(priceFeed.token0()) != Currency.unwrap(key.currency0)
                || address(priceFeed.token1()) != Currency.unwrap(key.currency1)
        ) {
            revert PriceFeedTokensNotMatch();
        }

        if (initializeHookData.DFF_max > 1000000) {
            revert DFFMaxTooLarge();
        }

        poolInfos[key.toId()] = PoolInfo({priceFeed: priceFeed, DFF_max: initializeHookData.DFF_max});

        return this.beforeInitialize.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 staticFee = key.fee & (~LPFeeLibrary.DYNAMIC_FEE_FLAG);

        if (_isSim) {
            _fee = staticFee;
            poolManager.updateDynamicLPFee(key, _fee);

            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId id = key.toId();

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        uint160 sqrtPriceX96After = _simulateSwap(key, params, hookData);

        uint160 priceX96Before = uint160(FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96));
        uint160 priceX96After = uint160(FullMath.mulDiv(sqrtPriceX96After, sqrtPriceX96After, FixedPoint96.Q96));

        PoolInfo memory poolInfo = poolInfos[id];
        uint256 priceX96Oracle = poolInfo.priceFeed.getPriceX96();

        uint256 sfX96;
        {
            if (priceX96After > priceX96Before && priceX96Oracle > priceX96Before) {
                sfX96 =
                    FullMath.mulDiv(priceX96After - priceX96Before, FixedPoint96.Q96, priceX96Oracle - priceX96Before);
            }
            if (priceX96After < priceX96Before && priceX96Oracle < priceX96Before) {
                sfX96 =
                    FullMath.mulDiv(priceX96Before - priceX96After, FixedPoint96.Q96, priceX96Before - priceX96Oracle);
            }
        }

        uint256 ipX96;
        {
            uint256 r = FullMath.mulDiv(priceX96Before, FixedPoint96.Q96, priceX96Oracle);
            ipX96 = r > FixedPoint96.Q96 ? r - FixedPoint96.Q96 : FixedPoint96.Q96 - r;
        }

        uint256 pifX96 = FullMath.mulDiv(sfX96, ipX96, FixedPoint96.Q96);

        SD59x18 DFF;
        uint256 fX96 = FullMath.mulDiv(key.fee.getInitialLPFee(), FixedPoint96.Q96, 1_000_000);
        if (pifX96 > fX96) {
            SD59x18 inter = inv(
                exp(
                    convert(int256(FullMath.mulDiv(pifX96 - fX96, FixedPoint96.Q96, fX96)))
                        / convert(int256(FixedPoint96.Q96))
                )
            );
            if (inter < UNIT) {
                DFF = convert(int256(int24(poolInfo.DFF_max))) * (UNIT - inter);
            }
        }

        if (DFF.isZero()) {
            _fee = staticFee;
            poolManager.updateDynamicLPFee(key, _fee);

            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (DFF > convert(1_000_000)) {
            revert DFFTooLarge();
        }

        _fee = uint24(int24(convert(DFF)));
        poolManager.updateDynamicLPFee(key, _fee);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Simulate `swap`
    function _simulateSwap(PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata hookData)
        internal
        returns (uint160 sqrtPriceX96)
    {
        _isSim = true;
        // TODO: Ugly, should add vault() to IFees interface!
        try CLPoolManager(address(poolManager)).vault().lock(
            abi.encode(CallbackData({sender: msg.sender, key: key, params: params, hookData: hookData}))
        ) {
            revert();
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            if (selector != SwapAndRevert.selector) {
                revert();
            }
            // Extract data by trimming the custom error selector (first 4 bytes)
            bytes memory data = new bytes(reason.length - 4);
            for (uint256 i = 4; i < reason.length; ++i) {
                data[i - 4] = reason[i];
            }
            sqrtPriceX96 = abi.decode(data, (uint160));
        }
        _isSim = false;
    }

    /// @dev Revert a custom error on purpose to achieve simulation of `swap`
    function lockAcquired(bytes calldata rawData) external override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        poolManager.swap(data.key, data.params, data.hookData);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(data.key.toId());
        revert SwapAndRevert(sqrtPriceX96);
    }
}

pragma solidity ^0.8.19;

import "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {BinBaseHook} from "../BinBaseHook.sol";

contract SampleBinDynamicFeeHook is BinBaseHook {
    using PoolIdLibrary for PoolKey;

    uint24 DEFAULT_LP_FEE = 3000;
    uint24 FREE_LP_FEE = 0;

    bool enableLPFeeOverride = false;

    constructor(IBinPoolManager poolManager) BinBaseHook(poolManager) {}

    function toggleLPFeeOverride() external {
        enableLPFeeOverride = !enableLPFeeOverride;
    }

    function setDynamicLpFee(PoolKey memory key, uint24 fee) public {
        poolManager.updateDynamicLPFee(key, fee);
    }

    function getHooksRegistrationBitmap()
        external
        pure
        override
        returns (uint16)
    {
        return
            _hooksRegistrationBitmapFrom(
                Permissions({
                    beforeInitialize: false,
                    afterInitialize: true,
                    beforeMint: true,
                    afterMint: false,
                    beforeBurn: false,
                    afterBurn: false,
                    beforeSwap: true,
                    afterSwap: false,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnDelta: false,
                    afterSwapReturnDelta: false,
                    afterMintReturnDelta: false,
                    afterBurnReturnDelta: false
                })
            );
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint24,
        bytes calldata
    ) external override returns (bytes4) {
        setDynamicLpFee(key, DEFAULT_LP_FEE);
        return this.afterInitialize.selector;
    }

    function beforeMint(
        address,
        PoolKey calldata,
        IBinPoolManager.MintParams calldata,
        bytes calldata
    ) external override returns (bytes4, uint24) {
        // if enableLPFeeOverride, the lp fee for the ongoing inner swap will be 0
        if (enableLPFeeOverride) {
            return (
                this.beforeMint.selector,
                LPFeeLibrary.OVERRIDE_FEE_FLAG & FREE_LP_FEE
            );
        }

        // otherwise, the lp fee will just be the default value
        return (this.beforeMint.selector, 0);
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        bool,
        int128,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // if enableLPFeeOverride, the lp fee for the ongoing swap will be 0
        if (enableLPFeeOverride) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                LPFeeLibrary.OVERRIDE_FEE_FLAG & FREE_LP_FEE
            );
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

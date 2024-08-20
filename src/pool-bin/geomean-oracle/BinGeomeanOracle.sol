// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_MINT_OFFSET,
    HOOKS_AFTER_MINT_OFFSET,
    HOOKS_BEFORE_BURN_OFFSET,
    HOOKS_AFTER_BURN_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET
} from "pancake-v4-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";

import {BinBaseHook} from "../BinBaseHook.sol";
import {OracleHelper} from "./libraries/OracleHelper.sol";
import {PairParameterHelper} from "./libraries/PairParameterHelper.sol";
import {SampleMath} from "./libraries/math/SampleMath.sol";

/// @notice A hook that allows a Bin pool to act as an oracle.
contract BinGeomeanOracle is BinBaseHook {
    using OracleHelper for OracleHelper.Oracle;
    using PoolIdLibrary for PoolKey;
    using PairParameterHelper for bytes32;
    using SampleMath for bytes32;

    mapping(PoolId => OracleHelper.Oracle) private _oracles;
    mapping(PoolId => bytes32) private _oracleParameters;

    event OracleLengthIncreased(address indexed sender, uint16 oracleLength);

    error OnlyOneOraclePoolAllowed();

    error OraclePoolMustLockLiquidity();

    constructor(IBinPoolManager poolManager) BinBaseHook(poolManager) {}

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeMint: true,
                afterMint: false,
                beforeBurn: true,
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

    /// @dev Called before any action that potentially modifies pool price or liquidity, such as swap or modify position
    function _updatePool(PoolKey calldata key) private {
        PoolId id = key.toId();
        OracleHelper.Oracle storage oracle = _oracles[id];
        bytes32 parameters = _oracleParameters[id];
        (uint24 activeId,,) = poolManager.getSlot0(id);
        oracle.update(parameters, activeId);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint24 activeId, bytes calldata hookData)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        if (key.fee != 0) {
            revert OnlyOneOraclePoolAllowed();
        }
        return this.beforeInitialize.selector;
    }

    function beforeMint(
        address sender,
        PoolKey calldata key,
        IBinPoolManager.MintParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        _updatePool(key);
        return this.beforeMint.selector;
    }

    function beforeBurn(
        address sender,
        PoolKey calldata key,
        IBinPoolManager.BurnParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        revert OraclePoolMustLockLiquidity();
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, BeforeSwapDelta, uint24) {
        _updatePool(key);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Returns the oracle parameters
     * @return sampleLifetime The sample lifetime for the oracle
     * @return size The size of the oracle
     * @return activeSize The active size of the oracle
     * @return lastUpdated The last updated timestamp of the oracle
     * @return firstTimestamp The first timestamp of the oracle, i.e. the timestamp of the oldest sample
     */
    function getOracleParameters(PoolKey calldata key)
        external
        view
        returns (uint8 sampleLifetime, uint16 size, uint16 activeSize, uint40 lastUpdated, uint40 firstTimestamp)
    {
        PoolId id = key.toId();
        bytes32 parameters = _oracleParameters[id];

        sampleLifetime = uint8(OracleHelper._MAX_SAMPLE_LIFETIME);

        uint16 oracleId = parameters.getOracleId();
        if (oracleId > 0) {
            bytes32 sample;
            OracleHelper.Oracle storage oracle = _oracles[id];
            (sample, activeSize) = oracle.getActiveSampleAndSize(oracleId);

            size = sample.getOracleLength();
            lastUpdated = sample.getSampleLastUpdate();

            if (lastUpdated == 0) activeSize = 0;

            if (activeSize > 0) {
                unchecked {
                    sample = oracle.getSample(1 + (oracleId % activeSize));
                }
                firstTimestamp = sample.getSampleLastUpdate();
            }
        }
    }

    /**
     * @notice Returns the cumulative values at a given timestamp
     * @dev The cumulative values are the cumulative id, the cumulative volatility and the cumulative bin crossed.
     * @param lookupTimestamp The timestamp at which to look up the cumulative values
     * @return cumulativeId The cumulative id at the given timestamp
     * @return cumulativeVolatility The cumulative volatility at the given timestamp
     * @return cumulativeBinCrossed The cumulative bin crossed at the given timestamp
     */
    function getOracleSampleAt(PoolKey calldata key, uint40 lookupTimestamp)
        external
        view
        returns (uint64 cumulativeId, uint64 cumulativeVolatility, uint64 cumulativeBinCrossed)
    {
        PoolId id = key.toId();
        bytes32 parameters = _oracleParameters[id];
        uint16 oracleId = parameters.getOracleId();

        if (oracleId == 0 || lookupTimestamp > block.timestamp) return (0, 0, 0);

        OracleHelper.Oracle storage oracle = _oracles[id];
        uint40 timeOfLastUpdate;
        (timeOfLastUpdate, cumulativeId, cumulativeVolatility, cumulativeBinCrossed) =
            oracle.getSampleAt(oracleId, lookupTimestamp);

        if (timeOfLastUpdate < lookupTimestamp) {
            parameters = parameters.updateVolatilityParameters(parameters.getActiveId(), lookupTimestamp);

            uint40 deltaTime = lookupTimestamp - timeOfLastUpdate;

            (uint24 activeId,,) = poolManager.getSlot0(id);
            cumulativeId += uint64(activeId) * deltaTime;
            cumulativeVolatility += uint64(parameters.getVolatilityAccumulator()) * deltaTime;
        }
    }

    /**
     * @notice Increase the length of the oracle used by the pool
     * @param newLength The new length of the oracle
     */
    function increaseOracleLength(PoolKey calldata key, uint16 newLength) external {
        PoolId id = key.toId();
        bytes32 parameters = _oracleParameters[id];

        uint16 oracleId = parameters.getOracleId();

        // activate the oracle if it is not active yet
        if (oracleId == 0) {
            oracleId = 1;
            _oracleParameters[id] = parameters.setOracleId(oracleId);
        }

        OracleHelper.Oracle storage oracle = _oracles[id];
        oracle.increaseLength(oracleId, newLength);

        emit OracleLengthIncreased(msg.sender, newLength);
    }
}

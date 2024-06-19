// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "@pancakeswap/v4-core/src/Vault.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {SortTokens} from "@pancakeswap/v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "@pancakeswap/v4-core/test/pool-cl/helpers/Deployers.sol";
import {Constants} from "@pancakeswap/v4-core/test/pool-cl/helpers/Constants.sol";
import {ICLSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-cl/interfaces/ICLSwapRouterBase.sol";
import {CLSwapRouter} from "@pancakeswap/v4-periphery/src/pool-cl/CLSwapRouter.sol";
import {NonfungiblePositionManager} from "@pancakeswap/v4-periphery/src/pool-cl/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from
    "@pancakeswap/v4-periphery/src/pool-cl/interfaces/INonfungiblePositionManager.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {CLGeomeanOracle} from "../../src/pool-cl/geomean-oracle/CLGeomeanOracle.sol";
import {Oracle} from "../../src/pool-cl/geomean-oracle/libraries/Oracle.sol";

contract CLGeomeanOracleHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    int24 constant MAX_TICK_SPACING = 32767;

    IVault vault;
    ICLPoolManager poolManager;
    NonfungiblePositionManager nfp;
    CLSwapRouter swapRouter;

    CLGeomeanOracle geomeanOracle;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        geomeanOracle = new CLGeomeanOracle(poolManager);

        nfp = new NonfungiblePositionManager(vault, poolManager, address(0), address(0));
        swapRouter = new CLSwapRouter(vault, poolManager, address(0));

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);

        address[2] memory approvalAddress = [address(nfp), address(swapRouter)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: geomeanOracle,
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(uint256(geomeanOracle.getHooksRegistrationBitmap())).setTickSpacing(MAX_TICK_SPACING)
        });
        id = key.toId();

        vm.warp(1);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function testBeforeInitializeRevertsIfNonZeroFee() public {
        PoolKey memory k = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: geomeanOracle,
            poolManager: poolManager,
            fee: 1,
            parameters: bytes32(uint256(geomeanOracle.getHooksRegistrationBitmap())).setTickSpacing(MAX_TICK_SPACING)
        });
        vm.expectRevert(CLGeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        poolManager.initialize(k, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function testBeforeInitializeRevertsIfNotMaxTickSpacing() public {
        PoolKey memory k = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: geomeanOracle,
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(uint256(geomeanOracle.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        vm.expectRevert(CLGeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        poolManager.initialize(k, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function testAfterInitializeState() public {
        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        CLGeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);
    }

    function testAfterInitializeObservation() public {
        poolManager.initialize(key, Constants.SQRT_RATIO_2_1, ZERO_BYTES);
        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testAfterInitializeObserve0() public {
        poolManager.initialize(key, Constants.SQRT_RATIO_2_1, ZERO_BYTES);
        uint32[] memory secondsAgo = new uint32[](1);
        secondsAgo[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            geomeanOracle.observe(key, secondsAgo);
        assertEq(tickCumulatives.length, 1);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 1);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    }

    function testBeforeModifyPositionNoObservations() public {
        poolManager.initialize(key, Constants.SQRT_RATIO_2_1, ZERO_BYTES);

        nfp.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: TickMath.minUsableTick(MAX_TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(MAX_TICK_SPACING),
                salt: bytes32(0),
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        CLGeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);

        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testBeforeModifyPositionObservation() public {
        poolManager.initialize(key, Constants.SQRT_RATIO_2_1, ZERO_BYTES);
        vm.warp(3); // advance 2 seconds
        nfp.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: TickMath.minUsableTick(MAX_TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(MAX_TICK_SPACING),
                salt: bytes32(0),
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        CLGeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);

        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 3);
        assertEq(observation.tickCumulative, 13862);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 680564733841876926926749214863536422912);
    }

    function testBeforeModifyPositionObservationAndCardinality() public {
        poolManager.initialize(key, Constants.SQRT_RATIO_2_1, ZERO_BYTES);
        vm.warp(3); // advance 2 seconds
        geomeanOracle.increaseCardinalityNext(key, 2);
        CLGeomeanOracle.ObservationState memory observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 2);

        nfp.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: TickMath.minUsableTick(MAX_TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(MAX_TICK_SPACING),
                salt: bytes32(0),
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        // cardinality is updated
        observationState = geomeanOracle.getState(key);
        assertEq(observationState.index, 1);
        assertEq(observationState.cardinality, 2);
        assertEq(observationState.cardinalityNext, 2);

        // index 0 is untouched
        Oracle.Observation memory observation = geomeanOracle.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);

        // index 1 is written
        observation = geomeanOracle.getObservation(key, 1);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 3);
        assertEq(observation.tickCumulative, 13862);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 680564733841876926926749214863536422912);
    }

    function testPermanentLiquidity() public {
        poolManager.initialize(key, Constants.SQRT_RATIO_2_1, ZERO_BYTES);
        vm.warp(3); // advance 2 seconds
        (uint256 tokenId, uint128 liquidity,,) = nfp.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: TickMath.minUsableTick(MAX_TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(MAX_TICK_SPACING),
                salt: bytes32(0),
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        vm.expectRevert(CLGeomeanOracle.OraclePoolMustLockLiquidity.selector);
        nfp.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }
}

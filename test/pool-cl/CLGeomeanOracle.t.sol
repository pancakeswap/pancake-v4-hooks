// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./helpers/MockCLPositionManager.sol";
import {CLGeomeanOracle} from "../../src/pool-cl/geomean-oracle/CLGeomeanOracle.sol";
import {Oracle} from "../../src/pool-cl/geomean-oracle/libraries/Oracle.sol";

contract CLGeomeanOracleHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    int24 constant MAX_TICK_SPACING = 32767;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLGeomeanOracle geomeanOracle;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        geomeanOracle = new CLGeomeanOracle(poolManager);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);

        address[3] memory approvalAddress = [address(cpm), address(swapRouter), address(permit2)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);

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
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(geomeanOracle),
                abi.encodeWithSelector(CLGeomeanOracle.OnlyOneOraclePoolAllowed.selector)
            )
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(geomeanOracle),
                abi.encodeWithSelector(CLGeomeanOracle.OnlyOneOraclePoolAllowed.selector)
            )
        );

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

        cpm.mint(
            key,
            TickMath.minUsableTick(MAX_TICK_SPACING),
            TickMath.maxUsableTick(MAX_TICK_SPACING),
            // liquidity:
            10e18,
            // amount0Max:
            100e18,
            // amount1Max:
            100e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
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

        cpm.mint(
            key,
            TickMath.minUsableTick(MAX_TICK_SPACING),
            TickMath.maxUsableTick(MAX_TICK_SPACING),
            // liquidity:
            10e18,
            // amount0Max:
            100e18,
            // amount1Max:
            100e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
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

        cpm.mint(
            key,
            TickMath.minUsableTick(MAX_TICK_SPACING),
            TickMath.maxUsableTick(MAX_TICK_SPACING),
            // liquidity:
            10e18,
            // amount0Max:
            100e18,
            // amount1Max:
            100e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
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

        (uint256 tokenId, uint128 liquidity) = cpm.mint(
            key,
            TickMath.minUsableTick(MAX_TICK_SPACING),
            TickMath.maxUsableTick(MAX_TICK_SPACING),
            // liquidity:
            10e18,
            // amount0Max:
            100e18,
            // amount1Max:
            100e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(geomeanOracle),
                abi.encodeWithSelector(CLGeomeanOracle.OraclePoolMustLockLiquidity.selector)
            )
        );
        cpm.decreaseLiquidity(
            // tokenId:
            tokenId,
            // poolKey:
            key,
            // liquidity:
            liquidity,
            // amount0Min:
            0,
            // amount1Min:
            0,
            // hookData:
            ZERO_BYTES
        );
    }
}

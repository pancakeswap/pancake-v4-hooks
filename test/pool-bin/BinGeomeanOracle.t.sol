// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {IBinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {BinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/BinPoolManager.sol";
import {Vault} from "@pancakeswap/v4-core/src/Vault.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {FeeLibrary} from "@pancakeswap/v4-core/src/libraries/FeeLibrary.sol";
import {BinPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Constants} from "@pancakeswap/v4-core/src/pool-bin/libraries/Constants.sol";
import {SortTokens} from "@pancakeswap/v4-core/test/helpers/SortTokens.sol";
import {IBinSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-bin/interfaces/IBinSwapRouterBase.sol";
import {BinSwapRouter} from "@pancakeswap/v4-periphery/src/pool-bin/BinSwapRouter.sol";
import {BinFungiblePositionManager} from "@pancakeswap/v4-periphery/src/pool-bin/BinFungiblePositionManager.sol";
import {IBinFungiblePositionManager} from
    "@pancakeswap/v4-periphery/src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {BinGeomeanOracle} from "../../src/pool-bin/geomean-oracle/BinGeomeanOracle.sol";
import {Deployers} from "./helpers/Deployers.sol";

contract BinGeomeanOracleHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;
    using BinPoolParametersHelper for bytes32;

    uint24 constant BIN_ID_1_1 = 2 ** 23;

    IVault vault;
    IBinPoolManager poolManager;
    BinFungiblePositionManager bfp;
    BinSwapRouter swapRouter;

    BinGeomeanOracle geomeanOracle;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        token0 = deployToken("MockToken0", "MT0", type(uint256).max);
        token1 = deployToken("MockToken1", "MT1", type(uint256).max);
        (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);

        (vault, poolManager) = createFreshManager();
        geomeanOracle = new BinGeomeanOracle(poolManager);

        bfp = new BinFungiblePositionManager(vault, poolManager, address(0));
        swapRouter = new BinSwapRouter(poolManager, vault, address(0));

        address[2] memory approvalAddress = [address(bfp), address(swapRouter)];
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
            parameters: bytes32(uint256(geomeanOracle.getHooksRegistrationBitmap())).setBinStep(60)
        });
        id = key.toId();
    }

    function test_RevertIfNonZeroFee() public {
        PoolKey memory k = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: geomeanOracle,
            poolManager: poolManager,
            fee: 1,
            parameters: bytes32(uint256(geomeanOracle.getHooksRegistrationBitmap())).setBinStep(60)
        });
        vm.expectRevert(BinGeomeanOracle.OnlyOneOraclePoolAllowed.selector);
        poolManager.initialize(k, BIN_ID_1_1, ZERO_BYTES);
    }

    function test_InitializePool() public {
        poolManager.initialize(key, BIN_ID_1_1, ZERO_BYTES);

        (uint8 sampleLifetime, uint16 size, uint16 activeSize, uint40 lastUpdated, uint40 firstTimestamp) =
            geomeanOracle.getOracleParameters(key);
        assertEq(size, 0);
        assertEq(activeSize, 0);
        assertEq(lastUpdated, 0);
        assertEq(firstTimestamp, 0);

        (uint64 cumulativeId, uint64 cumulativeVolatility, uint64 cumulativeBinCrossed) =
            geomeanOracle.getOracleSampleAt(key, 1);
        assertEq(cumulativeId, 0);
        assertEq(cumulativeVolatility, 0);
        assertEq(cumulativeBinCrossed, 0);
    }

    function test_AddLiquidity() public {
        poolManager.initialize(key, BIN_ID_1_1, ZERO_BYTES);

        geomeanOracle.increaseOracleLength(key, 1);

        {
            uint256 numBins = 1;
            int256[] memory deltaIds = new int256[](numBins);
            deltaIds[0] = 0;
            uint256[] memory distributionX = new uint256[](numBins);
            distributionX[0] = Constants.PRECISION;
            uint256[] memory distributionY = new uint256[](numBins);
            distributionY[0] = Constants.PRECISION;
            (,, uint256[] memory tokenIds, uint256[] memory liquidityMinted) = bfp.addLiquidity(
                IBinFungiblePositionManager.AddLiquidityParams({
                    poolKey: key,
                    amount0: 1e18,
                    amount1: 1e18,
                    amount0Min: 0,
                    amount1Min: 0,
                    activeIdDesired: BIN_ID_1_1,
                    idSlippage: 0,
                    deltaIds: deltaIds,
                    distributionX: distributionX,
                    distributionY: distributionY,
                    to: address(this),
                    deadline: block.timestamp
                })
            );

            (uint8 sampleLifetime, uint16 size, uint16 activeSize, uint40 lastUpdated, uint40 firstTimestamp) =
                geomeanOracle.getOracleParameters(key);
            assertEq(size, 1);
            assertEq(activeSize, 1);
            assertEq(lastUpdated, 1);
            assertEq(firstTimestamp, 1);

            (uint64 cumulativeId, uint64 cumulativeVolatility, uint64 cumulativeBinCrossed) =
                geomeanOracle.getOracleSampleAt(key, 1);
            assertEq(cumulativeId, BIN_ID_1_1);
            assertEq(cumulativeVolatility, 0);
            assertEq(cumulativeBinCrossed, BIN_ID_1_1);
        }

        vm.warp(3); // advance 2 seconds

        {
            uint256 numBins = 1;
            int256[] memory deltaIds = new int256[](numBins);
            deltaIds[0] = 0;
            uint256[] memory distributionX = new uint256[](numBins);
            distributionX[0] = Constants.PRECISION;
            uint256[] memory distributionY = new uint256[](numBins);
            distributionY[0] = Constants.PRECISION;
            (,, uint256[] memory tokenIds, uint256[] memory liquidityMinted) = bfp.addLiquidity(
                IBinFungiblePositionManager.AddLiquidityParams({
                    poolKey: key,
                    amount0: 1e18,
                    amount1: 1e18,
                    amount0Min: 0,
                    amount1Min: 0,
                    activeIdDesired: BIN_ID_1_1,
                    idSlippage: 0,
                    deltaIds: deltaIds,
                    distributionX: distributionX,
                    distributionY: distributionY,
                    to: address(this),
                    deadline: block.timestamp
                })
            );

            (uint8 sampleLifetime, uint16 size, uint16 activeSize, uint40 lastUpdated, uint40 firstTimestamp) =
                geomeanOracle.getOracleParameters(key);
            assertEq(size, 1);
            assertEq(activeSize, 1);
            assertEq(lastUpdated, 3);
            assertEq(firstTimestamp, 3);

            (uint64 cumulativeId, uint64 cumulativeVolatility, uint64 cumulativeBinCrossed) =
                geomeanOracle.getOracleSampleAt(key, 3);
            assertEq(cumulativeId, 3 * uint64(BIN_ID_1_1));
            assertEq(cumulativeVolatility, 0);
            assertEq(cumulativeBinCrossed, 3 * uint64(BIN_ID_1_1));
        }
    }

    function test_RevertIfRemoveLiquidity() public {
        poolManager.initialize(key, BIN_ID_1_1, ZERO_BYTES);

        uint256 numBins = 1;
        int256[] memory deltaIds = new int256[](numBins);
        deltaIds[0] = 0;
        uint256[] memory distributionX = new uint256[](numBins);
        distributionX[0] = Constants.PRECISION;
        uint256[] memory distributionY = new uint256[](numBins);
        distributionY[0] = Constants.PRECISION;
        (,, uint256[] memory tokenIds, uint256[] memory liquidityMinted) = bfp.addLiquidity(
            IBinFungiblePositionManager.AddLiquidityParams({
                poolKey: key,
                amount0: 1e18,
                amount1: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                activeIdDesired: BIN_ID_1_1,
                idSlippage: 0,
                deltaIds: deltaIds,
                distributionX: distributionX,
                distributionY: distributionY,
                to: address(this),
                deadline: block.timestamp
            })
        );

        vm.expectRevert(BinGeomeanOracle.OraclePoolMustLockLiquidity.selector);
        bfp.removeLiquidity(
            IBinFungiblePositionManager.RemoveLiquidityParams({
                poolKey: key,
                amount0Min: 0,
                amount1Min: 0,
                ids: tokenIds,
                amounts: liquidityMinted,
                from: address(this),
                to: address(this),
                deadline: block.timestamp
            })
        );
    }
}

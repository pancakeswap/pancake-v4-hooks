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

import {BinVeCakeExclusiveHook} from "../../src/pool-bin/vecake-exclusive/BinVeCakeExclusiveHook.sol";
import {Deployers} from "./helpers/Deployers.sol";

contract BinVeCakeExclusiveHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;
    using BinPoolParametersHelper for bytes32;

    uint24 constant BIN_ID_1_1 = 2 ** 23;

    IVault vault;
    IBinPoolManager poolManager;
    BinFungiblePositionManager bfp;
    BinSwapRouter swapRouter;

    BinVeCakeExclusiveHook veCakeExclusiveHook;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    MockERC20 veCake;
    address nonHolder = address(0x1);

    function setUp() public {
        token0 = deployToken("MockToken0", "MT0", type(uint256).max);
        token1 = deployToken("MockToken1", "MT1", type(uint256).max);
        veCake = deployToken("MockVeCake", "MVC", type(uint256).max);
        (currency0, currency1) = SortTokens.sort(token0, token1);

        (vault, poolManager) = createFreshManager();
        veCakeExclusiveHook = new BinVeCakeExclusiveHook(poolManager, address(veCake));

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
            hooks: veCakeExclusiveHook,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(veCakeExclusiveHook.getHooksRegistrationBitmap())).setBinStep(60)
        });
        id = key.toId();

        poolManager.initialize(key, BIN_ID_1_1, ZERO_BYTES);

        uint256 numBins = 1;
        int256[] memory deltaIds = new int256[](numBins);
        deltaIds[0] = 0;
        uint256[] memory distributionX = new uint256[](numBins);
        distributionX[0] = Constants.PRECISION;
        uint256[] memory distributionY = new uint256[](numBins);
        distributionY[0] = Constants.PRECISION;
        bfp.addLiquidity(
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
    }

    function test_SwapRevertIfNotHolder() public {
        vm.startPrank(nonHolder, nonHolder);
        vm.expectRevert(BinVeCakeExclusiveHook.NotVeCakeHolder.selector);
        swapRouter.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        vm.stopPrank();
    }

    function test_Swap() public {
        vm.startPrank(address(this), address(this));
        swapRouter.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        vm.stopPrank();
    }
}

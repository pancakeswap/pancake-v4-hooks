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
import {FeeLibrary} from "@pancakeswap/v4-core/src/libraries/FeeLibrary.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "@pancakeswap/v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "@pancakeswap/v4-core/test/pool-cl/helpers/Deployers.sol";
import {ICLSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-cl/interfaces/ICLSwapRouterBase.sol";
import {CLSwapRouter} from "@pancakeswap/v4-periphery/src/pool-cl/CLSwapRouter.sol";
import {NonfungiblePositionManager} from "@pancakeswap/v4-periphery/src/pool-cl/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from
    "@pancakeswap/v4-periphery/src/pool-cl/interfaces/INonfungiblePositionManager.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {CLVeCakeExclusiveHook} from "../../src/pool-cl/vecake-exclusive/CLVeCakeExclusiveHook.sol";

contract CLVeCakeExclusiveHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;
    using CLPoolParametersHelper for bytes32;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    IVault vault;
    ICLPoolManager poolManager;
    NonfungiblePositionManager nfp;
    CLSwapRouter swapRouter;

    CLVeCakeExclusiveHook veCakeExclusiveHook;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    MockERC20 veCake;
    address nonHolder = address(0x1);

    function setUp() public {
        MockERC20[] memory tokens = deployTokens(3, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        veCake = tokens[2];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        (vault, poolManager) = createFreshManager();
        veCakeExclusiveHook = new CLVeCakeExclusiveHook(poolManager, address(veCake));

        nfp = new NonfungiblePositionManager(vault, poolManager, address(0), address(0));
        swapRouter = new CLSwapRouter(vault, poolManager, address(0));

        address[2] memory approvalAddress = [address(nfp), address(swapRouter)];
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
            parameters: bytes32(uint256(veCakeExclusiveHook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        nfp.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function test_SwapRevertIfNotHolder() public {
        vm.startPrank(nonHolder, nonHolder);
        vm.expectRevert(CLVeCakeExclusiveHook.NotVeCakeHolder.selector);
        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        vm.stopPrank();
    }

    function test_Swap() public {
        vm.startPrank(address(this), address(this));
        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        vm.stopPrank();
    }
}

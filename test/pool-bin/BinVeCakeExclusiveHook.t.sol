// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {IBinHooks} from "pancake-v4-core/src/pool-bin/interfaces/IBinHooks.sol";
import {CustomRevert} from "pancake-v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Constants} from "pancake-v4-core/src/pool-bin/libraries/Constants.sol";
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {IBinPositionManager} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IBinRouterBase} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Deployers} from "./helpers/Deployers.sol";
import {MockBinPositionManager} from "./helpers/MockBinPositionManager.sol";
import {MockBinSwapRouter} from "./helpers/MockBinSwapRouter.sol";
import {BinVeCakeExclusiveHook} from "../../src/pool-bin/vecake-exclusive/BinVeCakeExclusiveHook.sol";

contract BinVeCakeExclusiveHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using BinPoolParametersHelper for bytes32;

    uint24 constant BIN_ID_1_1 = 2 ** 23;

    IVault vault;
    IBinPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockBinPositionManager bpm;
    MockBinSwapRouter swapRouter;

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

        permit2 = IAllowanceTransfer(deployPermit2());
        bpm = new MockBinPositionManager(vault, poolManager, permit2);
        swapRouter = new MockBinSwapRouter(vault, poolManager);

        address[3] memory approvalAddress = [address(bpm), address(swapRouter), address(permit2)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(bpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(bpm), type(uint160).max, type(uint48).max);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: veCakeExclusiveHook,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(veCakeExclusiveHook.getHooksRegistrationBitmap())).setBinStep(60)
        });
        id = key.toId();

        poolManager.initialize(key, BIN_ID_1_1);

        uint256 numBins = 1;
        int256[] memory deltaIds = new int256[](numBins);
        deltaIds[0] = 0;
        uint256[] memory distributionX = new uint256[](numBins);
        distributionX[0] = Constants.PRECISION;
        uint256[] memory distributionY = new uint256[](numBins);
        distributionY[0] = Constants.PRECISION;
        bpm.addLiquidity(
            IBinPositionManager.BinAddLiquidityParams({
                poolKey: key,
                amount0: 1e18,
                amount1: 1e18,
                amount0Max: 1e18,
                amount1Max: 1e18,
                activeIdDesired: BIN_ID_1_1,
                idSlippage: 0,
                deltaIds: deltaIds,
                distributionX: distributionX,
                distributionY: distributionY,
                to: address(this),
                hookData: ZERO_BYTES
            })
        );
    }

    function test_SwapRevertIfNotHolder() public {
        vm.prank(nonHolder, nonHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(key.hooks),
                IBinHooks.beforeSwap.selector,
                abi.encodeWithSelector(BinVeCakeExclusiveHook.NotVeCakeHolder.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key,
                swapForY: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    function test_Swap() public {
        vm.prank(address(this), address(this));
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key,
                swapForY: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }
}

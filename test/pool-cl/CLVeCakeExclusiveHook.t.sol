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
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./helpers/MockCLPositionManager.sol";
import {PositionConfig} from "pancake-v4-periphery/src/pool-cl/libraries/PositionConfig.sol";
import {CLVeCakeExclusiveHook} from "../../src/pool-cl/vecake-exclusive/CLVeCakeExclusiveHook.sol";

contract CLVeCakeExclusiveHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLVeCakeExclusiveHook veCakeExclusiveHook;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;
    PositionConfig config;

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

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

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
            hooks: veCakeExclusiveHook,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(veCakeExclusiveHook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        cpm.mint(
            config,
            // liquidity:
            10e18,
            // amount0Max:
            1e18,
            // amount1Max:
            1e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
        );
    }

    function test_SwapRevertIfNotHolder() public {
        vm.prank(nonHolder, nonHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(veCakeExclusiveHook),
                abi.encodeWithSelector(CLVeCakeExclusiveHook.NotVeCakeHolder.selector)
            )
        );
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    function test_Swap() public {
        vm.prank(address(this), address(this));
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }
}

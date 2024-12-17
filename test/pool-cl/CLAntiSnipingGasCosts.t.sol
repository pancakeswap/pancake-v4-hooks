// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./helpers/MockCLPositionManager.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLAntiSniping} from "../../src/pool-cl/anti-sniping/CLAntiSniping.sol";
import {Planner, Plan} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";

contract AntiSnipingTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    uint24 constant FEE = 3000;
    uint128 constant POSITION_LOCK_DURATION = 1000;
    uint128 constant SAME_BLOCK_POSITIONS_LIMIT = 50;

    address constant ALICE = address(0x1111); // ALICE is an honest liquidity provider
    bytes32 constant ALICE_SALT = 0x0000000000000000000000000000000000000000000000000000000000000001;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLAntiSniping antiSniping;
    CLPoolManagerRouter router;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;
    uint256 aliceTokenId;
    uint256 bobTokenId;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        antiSniping = new CLAntiSniping(poolManager, POSITION_LOCK_DURATION, SAME_BLOCK_POSITIONS_LIMIT);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);
        router = new CLPoolManagerRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        address[5] memory approvalAddress = [address(cpm), address(swapRouter), address(router), address(antiSniping), address(permit2)];

        vm.startPrank(ALICE);
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: antiSniping,
            poolManager: poolManager,
            fee: FEE,
            parameters: bytes32(uint256(antiSniping.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1);

        token0.transfer(ALICE, 10000 ether);
        token1.transfer(ALICE, 10000 ether);

        // Add positions up to the limit
        for (uint256 i = 0; i < SAME_BLOCK_POSITIONS_LIMIT; ++i) {
            _mintLiquidityPosition(ALICE, -60, 60, 10 ether, ZERO_BYTES);
            vm.roll(i+2);
        }
    }

    // Helper function to mint liquidity positions (add)
    function _mintLiquidityPosition(
        address user,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta,
        bytes memory hookData
    ) internal returns (uint256 tokenId) {
        vm.prank(user);
        (tokenId, ) = cpm.mint(
            key,
            tickLower,
            tickUpper,
            // liquidity:
            liquidityDelta,
            // amount0Max:
            10000e18,
            // amount1Max:
            10000e18,
            // owner:
            user,
            // hookData:
            hookData
        );
    }

    // Helper function to decrease liquidity positions (remove)
    function _decreaseLiquidityPosition(
        address user,
        uint256 tokenId,
        uint256 liquidityDelta,
        bytes memory hookData
    ) internal {
        vm.prank(user);
        cpm.decreaseLiquidity(
        // tokenId:
            tokenId,
            // poolKey:
            key,
            // liquidity:
            liquidityDelta,
            // amount0Min:
            0,
            // amount1Min:
            0,
            // hookData:
            hookData
        );
    }

    // Helper function to perform a swap
    function _performSwapExactOutputSingle(address user, bool zeroForOne, uint128 amountOut) internal {
        vm.prank(user);
        swapRouter.exactOutputSingle(
            ICLRouterBase.CLSwapExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: 1.01 ether,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    /// @notice Test that exceeding same block position limit reverts
    function testGasCosts() public {
        _mintLiquidityPosition(ALICE, -60, 60, 10 ether, ZERO_BYTES);
    }

}
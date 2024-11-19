// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {CommonBase} from "forge-std/Base.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {ICLPositionDescriptor} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "pancake-v4-periphery/src/interfaces/external/IWETH9.sol";
import {CLPositionManager} from "pancake-v4-periphery/src/pool-cl/CLPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Planner, Plan} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";

contract MockCLPositionManager is CLPositionManager, CommonBase {
    using Planner for Plan;

    constructor(IVault _vault, ICLPoolManager _clPoolManager, IAllowanceTransfer _permit2)
        CLPositionManager(_vault, _clPoolManager, _permit2, 500000, ICLPositionDescriptor(address(0)), IWETH9(address(0)))
    {}

    function mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) external payable returns (uint256 tokenId, uint128 liquidityMinted) {
        Plan memory planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        );
        bytes memory data = planner.finalizeModifyLiquidityWithClose(poolKey);

        tokenId = nextTokenId;

        vm.prank(msg.sender);
        this.modifyLiquidities(data, block.timestamp);

        liquidityMinted = _getLiquidity(tokenId, poolKey, tickLower, tickUpper);
    }

    function decreaseLiquidity(
        uint256 tokenId,
        PoolKey calldata poolKey,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) external payable {
        Plan memory planner = Planner.init().add(
            Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, liquidity, amount0Min, amount1Min, hookData)
        );
        bytes memory data = planner.finalizeModifyLiquidityWithClose(poolKey);

        vm.prank(msg.sender);
        this.modifyLiquidities(data, block.timestamp);
    }
}

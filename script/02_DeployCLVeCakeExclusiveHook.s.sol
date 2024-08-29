// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {CLVeCakeExclusiveHook} from "../src/pool-cl/vecake-exclusive/CLVeCakeExclusiveHook.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";

/**
 * forge script script/02_DeployCLVeCakeExclusiveHook.s.sol:DeployCLVeCakeExclusiveHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLVeCakeExclusiveHookScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        address veCake = getAddressFromConfig("mockVeCake");
        emit log_named_address("VeCake", veCake);

        CLVeCakeExclusiveHook clVeCakeExclusiveHook =
            new CLVeCakeExclusiveHook(ICLPoolManager(clPoolManager), address(veCake));
        emit log_named_address("CLVeCakeExclusiveHook", address(clVeCakeExclusiveHook));

        vm.stopBroadcast();
    }
}

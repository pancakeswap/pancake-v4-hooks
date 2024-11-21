// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {CLVeCakeExclusiveHook} from "../src/pool-cl/vecake-exclusive/CLVeCakeExclusiveHook.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

/**
 * Step 1: Deploy
 * forge script script/02_DeployCLVeCakeExclusiveHook.s.sol:DeployCLVeCakeExclusiveHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> CLVeCakeExclusiveHook --watch \
 *      --chain <chain_id> --constructor-args $(cast abi-encode "constructor(address, address)" "<clPoolManager> <veCake>")
 */
contract DeployCLVeCakeExclusiveHookScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("PANCAKE-V4-HOOKS/CLVeCakeExclusiveHook/0.90");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        address veCake = getAddressFromConfig("mockVeCake");
        emit log_named_address("VeCake", veCake);

        bytes memory creationCode =
            abi.encodePacked(type(CLVeCakeExclusiveHook).creationCode, abi.encode(clPoolManager, veCake));
        address clVeCakeExclusiveHook =
            factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);

        emit log_named_address("CLVeCakeExclusiveHook", address(clVeCakeExclusiveHook));

        vm.stopBroadcast();
    }
}

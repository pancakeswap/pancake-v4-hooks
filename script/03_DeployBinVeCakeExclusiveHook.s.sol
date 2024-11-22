// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {BinVeCakeExclusiveHook} from "../src/pool-bin/vecake-exclusive/BinVeCakeExclusiveHook.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

/**
 * Step 1: Deploy
 * forge script script/03_DeployBinVeCakeExclusiveHook.s.sol:DeployBinVeCakeExclusiveHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> BinVeCakeExclusiveHook --watch \
 *      --chain <chain_id> --constructor-args $(cast abi-encode "constructor(address, address)" "<binPoolManager> <veCake>")
 */
contract DeployBinVeCakeExclusiveHookScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("PANCAKE-V4-HOOKS/BinVeCakeExclusiveHook/0.90");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        address veCake = getAddressFromConfig("mockVeCake");
        emit log_named_address("VeCake", veCake);

        bytes memory creationCode =
            abi.encodePacked(type(BinVeCakeExclusiveHook).creationCode, abi.encode(binPoolManager, veCake));
        address binVeCakeExclusiveHook =
            factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);

        emit log_named_address("BinVeCakeExclusiveHook", address(binVeCakeExclusiveHook));

        vm.stopBroadcast();
    }
}

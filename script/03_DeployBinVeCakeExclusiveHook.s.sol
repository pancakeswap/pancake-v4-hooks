// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {BinVeCakeExclusiveHook} from "../src/pool-bin/vecake-exclusive/BinVeCakeExclusiveHook.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";

/**
 * forge script script/03_DeployBinVeCakeExclusiveHook.s.sol:DeployBinVeCakeExclusiveHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinVeCakeExclusiveHookScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        address veCake = getAddressFromConfig("veCake");
        emit log_named_address("VeCake", veCake);

        BinVeCakeExclusiveHook binVeCakeExclusiveHook =
            new BinVeCakeExclusiveHook(IBinPoolManager(binPoolManager), address(veCake));
        emit log_named_address("CLVeCakeExclusiveHook", address(binVeCakeExclusiveHook));

        vm.stopBroadcast();
    }
}

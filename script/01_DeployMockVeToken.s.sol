// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/**
 * forge script script/01_DeployMockVeToken.s.sol:DeployMockVeTokenScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployMockVeTokenScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockERC20 VeCake = new MockERC20("MockVeCake", "VeCake", 18);
        emit log_named_address("MockVeCake", address(VeCake));

        vm.stopBroadcast();
    }
}

pragma solidity ^0.8.19;

import {CommonBase} from "forge-std/Base.sol";
import {MockV4Router} from "pancake-v4-periphery/test/mocks/MockV4Router.sol";
import {IV4Router} from "pancake-v4-periphery/src/interfaces/IV4Router.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Planner, Plan} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

contract MockBinSwapRouter is MockV4Router, CommonBase {
    using Planner for Plan;

    constructor(IVault _vault, IBinPoolManager _binPoolManager)
        MockV4Router(_vault, ICLPoolManager(address(0)), _binPoolManager)
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert();
        _;
    }

    function exactInputSingle(IV4Router.BinSwapExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        Currency inputCurrency = params.swapForY ? params.poolKey.currency0 : params.poolKey.currency1;
        Currency outputCurrency = params.swapForY ? params.poolKey.currency1 : params.poolKey.currency0;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }

    function exactInput(IV4Router.BinSwapExactInputParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_IN, abi.encode(params));
        Currency inputCurrency = params.currencyIn;
        Currency outputCurrency = params.path[params.path.length - 1].intermediateCurrency;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }

    function exactOutputSingle(IV4Router.BinSwapExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        Currency inputCurrency = params.swapForY ? params.poolKey.currency0 : params.poolKey.currency1;
        Currency outputCurrency = params.swapForY ? params.poolKey.currency1 : params.poolKey.currency0;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }

    function exactOutput(IV4Router.BinSwapExactOutputParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_OUT, abi.encode(params));
        Currency inputCurrency = params.path[params.path.length - 1].intermediateCurrency;
        Currency outputCurrency = params.currencyOut;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }
}

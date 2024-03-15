// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_MINT_OFFSET,
    HOOKS_AFTER_MINT_OFFSET,
    HOOKS_BEFORE_BURN_OFFSET,
    HOOKS_AFTER_BURN_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET,
    HOOKS_NO_OP_OFFSET
} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinHooks.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@pancakeswap/v4-core/src/interfaces/IHooks.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {IBinHooks} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IBinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/BinPoolManager.sol";

/// @notice BaseHook abstract contract for Bin pool hooks to inherit
abstract contract BinBaseHook is IBinHooks {
    /// @notice The sender is not the pool manager
    error NotPoolManager();

    /// @notice The sender is not the vault
    error NotVault();

    /// @notice The sender is not this contract
    error NotSelf();

    /// @notice The pool key does not include this hook
    error InvalidPool();

    /// @notice The delegation of lockAcquired failed
    error LockFailure();

    /// @notice The method is not implemented
    error HookNotImplemented();

    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeMint;
        bool afterMint;
        bool beforeBurn;
        bool afterBurn;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool noOp;
    }

    /// @notice The address of the pool manager
    IBinPoolManager public immutable poolManager;

    /// @notice The address of the vault
    IVault public immutable vault;

    constructor(IBinPoolManager _poolManager) {
        poolManager = _poolManager;
        vault = BinPoolManager(address(poolManager)).vault();
    }

    /// @dev Only the pool manager may call this function
    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Only the vault may call this function
    modifier vaultOnly() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @dev Only pools with hooks set to this contract may call this function
    modifier onlyValidPools(IHooks hooks) {
        if (address(hooks) != address(this)) revert InvalidPool();
        _;
    }

    /// @dev Delegate calls to corresponding methods according to callback data
    function lockAcquired(bytes calldata data) external virtual vaultOnly returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    /// @inheritdoc IBinHooks
    function beforeInitialize(address, PoolKey calldata, uint24, bytes calldata) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function afterInitialize(address, PoolKey calldata, uint24, bytes calldata) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function beforeMint(address, PoolKey calldata, IBinPoolManager.MintParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function afterMint(address, PoolKey calldata, IBinPoolManager.MintParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function beforeBurn(address, PoolKey calldata, IBinPoolManager.BurnParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function afterBurn(address, PoolKey calldata, IBinPoolManager.BurnParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function beforeSwap(address, PoolKey calldata, bool, uint128, bytes calldata) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function afterSwap(address, PoolKey calldata, bool, uint128, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IBinHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @dev A convenience method to construct the hook registration map.
    function _hooksRegistrationBitmapFrom(Permissions memory permissions) internal pure returns (uint16) {
        return uint16(
            (permissions.beforeInitialize ? 1 << HOOKS_BEFORE_INITIALIZE_OFFSET : 0)
                | (permissions.afterInitialize ? 1 << HOOKS_AFTER_INITIALIZE_OFFSET : 0)
                | (permissions.beforeMint ? 1 << HOOKS_BEFORE_MINT_OFFSET : 0)
                | (permissions.afterMint ? 1 << HOOKS_AFTER_MINT_OFFSET : 0)
                | (permissions.beforeBurn ? 1 << HOOKS_BEFORE_BURN_OFFSET : 0)
                | (permissions.afterBurn ? 1 << HOOKS_AFTER_BURN_OFFSET : 0)
                | (permissions.beforeSwap ? 1 << HOOKS_BEFORE_SWAP_OFFSET : 0)
                | (permissions.afterSwap ? 1 << HOOKS_AFTER_SWAP_OFFSET : 0)
                | (permissions.beforeDonate ? 1 << HOOKS_BEFORE_DONATE_OFFSET : 0)
                | (permissions.afterDonate ? 1 << HOOKS_AFTER_DONATE_OFFSET : 0)
                | (permissions.noOp ? 1 << HOOKS_NO_OP_OFFSET : 0)
        );
    }
}

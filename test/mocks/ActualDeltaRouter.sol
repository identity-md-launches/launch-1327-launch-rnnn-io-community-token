// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice A test router that settles what the PoolManager actually records for it after the swap,
/// as the Universal Router's SETTLE_ALL and TAKE_ALL do, rather than the `BalanceDelta` the swap
/// returned. The two differ when the hook refunds part of a declared fee to the router inside the
/// swap. v4-core's `PoolSwapTest` requires them to be equal and cannot drive that path.
/// @dev The caller hands over `maxIn` of the input currency up front; whatever the swap does not use
/// is returned at the end. Nothing is pulled from anyone but `msg.sender`.
contract ActualDeltaRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct CallbackData {
        address swapper;
        PoolKey key;
        SwapParams params;
    }

    error NotManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 maxIn) external returns (BalanceDelta delta) {
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        IERC20Minimal(Currency.unwrap(input)).transferFrom(msg.sender, address(this), maxIn);
        delta = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
        uint256 left = input.balanceOfSelf();
        if (left > 0) input.transfer(msg.sender, left);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, "");
        _close(data.key.currency0, data.swapper);
        _close(data.key.currency1, data.swapper);
        return abi.encode(delta);
    }

    function _close(Currency currency, address swapper) internal {
        int256 owed = manager.currencyDelta(address(this), currency);
        if (owed < 0) {
            manager.sync(currency);
            currency.transfer(address(manager), uint256(-owed));
            manager.settle();
        } else if (owed > 0) {
            manager.take(currency, swapper, uint256(owed));
        }
    }
}

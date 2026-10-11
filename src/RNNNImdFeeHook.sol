// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @title RNNNImdFeeHook
/// @notice The one-rule hook for the RNNN/IMD pool: every swap pays 1% of its IMD side, in IMD, to a
/// fixed recipient. Nothing else.
///
/// @dev Design, in one place:
///
/// - The fee is always taken from the IMD side of the swap, never from RNNN, and it is never swapped
///   into anything else. The recipient receives IMD.
/// - When IMD is the *specified* currency (an exact-input buy, or an exact-output sell), the fee is
///   declared in `beforeSwap` through `beforeSwapReturnDelta`: the pool trades 1% less IMD on a buy
///   and 1% more on a sell, and the swapper's total is unchanged from what they asked for.
/// - When IMD is the *unspecified* currency (an exact-output buy, or an exact-input sell), the fee is
///   declared in `afterSwap` through `afterSwapReturnDelta`: the swapper pays 1% more IMD on a buy and
///   receives 1% less IMD on a sell.
/// - Either way the fee is 1% (floor) of the IMD amount the pool quoted for the swap, and the hook
///   settles it in `afterSwap`. If the PoolManager already holds enough IMD, the fee is transferred to
///   the recipient at once with `take`. If it does not (a freshly seeded pool holds no IMD until the
///   first buy settles), the hook mints itself an ERC-6909 claim for the amount instead, and the claim
///   is redeemed on the next swap that finds enough IMD or by anyone calling `collectPending`. No swap
///   ever fails because the fee could not be delivered.
/// - `beforeInitialize` accepts any pool that has IMD on one side, from any initializer, with any LP
///   fee and tick spacing. It exists so nobody can open the launch pool before the hook has code.
/// - There is no owner, no pause, no mint, no setter, no other fee, and nothing that blocks or alters
///   a swap beyond the fee above. Both configuration values are immutable constructor arguments.
contract RNNNImdFeeHook is IHooks, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /// @notice The fee, in basis points of the IMD side of each swap. 100 bps = 1%.
    uint256 public constant FEE_BPS = 100;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;

    /// @notice IMD, the pair currency the fee is taken in.
    Currency public immutable imd;

    /// @notice Where every fee goes. Fixed at construction, can never change.
    address public immutable feeRecipient;

    /// @notice A fee was delivered to `feeRecipient`, in IMD.
    event FeePaid(uint256 amount);
    /// @notice A fee could not be delivered yet because the PoolManager did not hold enough IMD; the
    /// hook holds it as an ERC-6909 claim until `collectPending` or a later swap delivers it.
    event FeeDeferred(uint256 amount);

    error NotPoolManager();
    error ZeroAddress();
    error PoolHasNoImdSide();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager (written "$poolManager" in the manifest).
    /// @param imd_ The IMD ERC-20 the pool pairs with (0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127 on
    /// Robinhood Chain).
    /// @param feeRecipient_ The address every fee is sent to (0x45c89d0cf0b8a05218506236fcfcb18da1d3ebe4).
    constructor(IPoolManager poolManager_, address imd_, address feeRecipient_) {
        if (address(poolManager_) == address(0) || imd_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        imd = Currency.wrap(imd_);
        feeRecipient = feeRecipient_;
        // The address this hook is deployed at must advertise exactly the permissions implemented
        // below; the PoolManager calls whatever the address claims.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice The callbacks this hook implements; the deployer mines an address carrying these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice IMD this hook is owed but has not yet been able to deliver, held as an ERC-6909 claim
    /// on the PoolManager.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), imd.toId());
    }

    /// @notice Deliver any pending fee claim to `feeRecipient`, as far as the PoolManager's IMD
    /// balance allows. Anyone may call this; the recipient is fixed.
    /// @return paid The amount of IMD delivered.
    function collectPending() external returns (uint256 paid) {
        paid = abi.decode(poolManager.unlock(""), (uint256));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reached through `collectPending`.
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 pending = pendingFees();
        uint256 available = imd.balanceOf(address(poolManager));
        uint256 amount = pending < available ? pending : available;
        if (amount > 0) {
            poolManager.burn(address(this), imd.toId(), amount);
            poolManager.take(imd, feeRecipient, amount);
            emit FeePaid(amount);
        }
        return abi.encode(amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Any initializer, any listed LP fee, any tick spacing: the only requirement is that the
    /// pool has an IMD side for the fee to come from.
    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!(key.currency0 == imd) && !(key.currency1 == imd)) revert PoolHasNoImdSide();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        BeforeSwapDelta delta = toBeforeSwapDelta(0, 0);
        if (_imdIsSpecified(key, params)) {
            // IMD is the specified amount: shave the fee off what the pool trades. The swapper's total
            // in IMD stays exactly what they specified.
            uint256 fee = _feeOf(_abs(params.amountSpecified));
            if (fee > 0) delta = toBeforeSwapDelta(fee.toInt128(), 0);
        }
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 fee;
        int128 hookDeltaUnspecified = 0;
        if (_imdIsSpecified(key, params)) {
            // Already declared in beforeSwap; only settle it here.
            fee = _feeOf(_abs(params.amountSpecified));
        } else {
            // IMD is the unspecified side: charge the fee on top of (buy) or out of (sell) what the
            // pool quoted.
            int256 imdAmount = key.currency0 == imd ? delta.amount0() : delta.amount1();
            fee = _feeOf(_abs(imdAmount));
            if (fee > 0) hookDeltaUnspecified = fee.toInt128();
        }
        if (fee > 0) _settleFee(fee);
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Deliver `fee` IMD to the recipient from the PoolManager's balance, or hold it as a claim
    /// when the manager does not hold enough yet. Whatever is delivered also carries along as much of
    /// any earlier claim as the balance allows. Called inside the swap's unlock, after the hook has
    /// been credited the fee, so the hook's deltas net to zero by the end of the callback.
    function _settleFee(uint256 fee) internal {
        uint256 available = imd.balanceOf(address(poolManager));
        if (available < fee) {
            poolManager.mint(address(this), imd.toId(), fee);
            emit FeeDeferred(fee);
            return;
        }
        uint256 payout = fee;
        uint256 pending = pendingFees();
        if (pending > 0) {
            uint256 room = available - fee;
            uint256 extra = pending < room ? pending : room;
            if (extra > 0) {
                poolManager.burn(address(this), imd.toId(), extra);
                payout += extra;
            }
        }
        poolManager.take(imd, feeRecipient, payout);
        emit FeePaid(payout);
    }

    /// @dev Whether IMD is the swap's specified currency: the input of an exact-input swap or the
    /// output of an exact-output swap.
    function _imdIsSpecified(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool imdIsCurrency0 = key.currency0 == imd;
        return specifiedIsCurrency0 == imdIsCurrency0;
    }

    function _feeOf(uint256 imdAmount) internal pure returns (uint256) {
        return imdAmount * FEE_BPS / BPS_DENOMINATOR;
    }

    function _abs(int256 value) internal pure returns (uint256) {
        // Safe: a negative value is negated first (checked arithmetic rejects type(int256).min), and
        // a non-negative int256 always fits in uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return value < 0 ? uint256(-value) : uint256(value);
    }
}

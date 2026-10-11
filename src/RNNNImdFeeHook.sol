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
/// - The fee is 1% (floor) of the IMD the pool actually traded in the swap, on every swap shape. It is
///   computed in `afterSwap` from the pool's own `BalanceDelta`, never from the amount the swapper
///   asked for, so a swap the pool fills only partly (a price limit reached, liquidity exhausted) pays
///   1% of what traded and nothing on what did not.
/// - When IMD is the *unspecified* currency (an exact-output buy, or an exact-input sell), the fee is
///   charged in `afterSwap` through `afterSwapReturnDelta`: the swapper pays 1% more IMD on a buy and
///   receives 1% less IMD on a sell.
/// - When IMD is the *specified* currency (an exact-input buy, or an exact-output sell), v4 only lets
///   a hook charge that currency in `beforeSwap`, before the fill is known. `beforeSwap` therefore
///   declares the fee a full fill would owe (X/101 of an exact input, Y/99 of an exact output, so that
///   it equals 1% of the pool's IMD leg when everything trades), and `afterSwap` compares it with the
///   fee the executed amount really owes. Any excess is returned to the swapper's router inside the
///   same unlock (`take` to the hook, `sync`, transfer, `settleFor(router)`), so the router settles
///   only what traded plus 1%. That refund is paid from the IMD the PoolManager holds; when it holds
///   too little (the launch pool before its first buy settles) a short fill is refused with
///   `ShortFillNotRefundable` rather than mischarged. A full fill never needs a refund.
/// - The hook settles the fee in `afterSwap`. If the PoolManager holds enough IMD and the recipient
///   accepts the transfer, the fee is delivered at once with `take`. If it does not (a freshly seeded
///   pool holds no IMD until the first buy settles), or the transfer to the recipient fails, the hook
///   mints itself an ERC-6909 claim for the amount instead, and the claim is redeemed on the next swap
///   that can deliver it or by anyone calling `collectPending`. No swap fails because the fee could
///   not be delivered.
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
    /// @dev An exact-input swap of X IMD covers the pool's leg E plus the fee E * 1%, so the full-fill
    /// fee is X * FEE_BPS / (BPS_DENOMINATOR + FEE_BPS) = X / 101. Written as a divisor so the
    /// arithmetic cannot overflow for any `amountSpecified`.
    uint256 internal constant EXACT_INPUT_FEE_DIVISOR = (BPS_DENOMINATOR + FEE_BPS) / FEE_BPS;
    /// @dev An exact-output swap for Y IMD is the pool's leg E minus the fee E * 1%, so the full-fill
    /// fee is Y * FEE_BPS / (BPS_DENOMINATOR - FEE_BPS) = Y / 99.
    uint256 internal constant EXACT_OUTPUT_FEE_DIVISOR = (BPS_DENOMINATOR - FEE_BPS) / FEE_BPS;
    /// @dev The largest delta v4 can carry; a declared fee is clamped to it so the hook never fails
    /// a cast where the pool itself would still trade.
    // Safe: type(int128).max is positive, so it fits uint128 unchanged.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 internal constant MAX_DELTA = uint256(uint128(type(int128).max));

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;

    /// @notice IMD, the pair currency the fee is taken in.
    Currency public immutable imd;

    /// @notice Where every fee goes. Fixed at construction, can never change.
    address public immutable feeRecipient;

    /// @notice A fee was delivered to `feeRecipient`, in IMD.
    event FeePaid(uint256 amount);
    /// @notice A fee could not be delivered yet, because the PoolManager did not hold enough IMD or
    /// the recipient refused the transfer; the hook holds it as an ERC-6909 claim until
    /// `collectPending` or a later swap delivers it.
    event FeeDeferred(uint256 amount);
    /// @notice A swap whose IMD side was specified filled only partly: the part of the declared fee
    /// that the executed amount did not owe was returned to the swapper's router.
    event FeeRefunded(uint256 amount);

    error NotPoolManager();
    error ZeroAddress();
    error PoolHasNoImdSide();
    error HookNotImplemented();
    /// @notice An IMD-specified swap filled short and the PoolManager held too little IMD to return
    /// the unowed part of the declared fee, so the swap is refused instead of overcharged.
    error ShortFillNotRefundable();

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
            // IMD is the specified amount: declare the fee a full fill owes, so the pool trades that
            // much less IMD on a buy and that much more on a sell. afterSwap trues it up to the fill.
            uint256 declared = _declaredFee(params);
            if (declared > 0) delta = toBeforeSwapDelta(declared.toInt128(), 0);
        }
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @inheritdoc IHooks
    /// @dev `delta` is the pool's own result, before the hook's deltas are applied to it, so its IMD
    /// amount is exactly what the pool traded: the base of the fee on every path.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        int256 imdAmount = key.currency0 == imd ? delta.amount0() : delta.amount1();
        uint256 fee = _feeOf(_abs(imdAmount));
        int128 hookDeltaUnspecified = 0;
        if (_imdIsSpecified(key, params)) {
            // beforeSwap already charged `declared`; keep what the fill owes and return the rest to
            // the swapper's router. On a full fill the two agree and nothing is returned.
            uint256 declared = _declaredFee(params);
            if (fee > declared) fee = declared;
            uint256 excess = declared - fee;
            if (excess > 0) _refund(sender, excess);
        } else {
            // IMD is the unspecified side: charge the fee on top of (buy) or out of (sell) what the
            // pool traded.
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
    /// when the manager does not hold enough yet or the recipient refuses the transfer. Whatever is
    /// delivered also carries along as much of any earlier claim as the balance allows. Called inside
    /// the swap's unlock, after the hook has been credited the fee, so the hook's deltas net to zero
    /// by the end of the callback.
    function _settleFee(uint256 fee) internal {
        uint256 available = imd.balanceOf(address(poolManager));
        if (available >= fee) {
            uint256 pending = pendingFees();
            uint256 room = available - fee;
            uint256 extra = pending < room ? pending : room;
            try poolManager.take(imd, feeRecipient, fee + extra) {
                if (extra > 0) poolManager.burn(address(this), imd.toId(), extra);
                emit FeePaid(fee + extra);
                return;
            } catch {}
        }
        poolManager.mint(address(this), imd.toId(), fee);
        emit FeeDeferred(fee);
    }

    /// @dev Return `amount` IMD of an over-declared fee to `router`, the contract that called
    /// `PoolManager.swap` for the swapper: take it from the PoolManager to the hook, then pay it
    /// straight back in on the router's behalf, so the router's IMD debt shrinks by `amount` and the
    /// hook ends with nothing. The round trip needs the manager to hold the IMD; when it does not, the
    /// short fill cannot be charged correctly and is refused.
    function _refund(address router, uint256 amount) internal {
        if (imd.balanceOf(address(poolManager)) < amount) revert ShortFillNotRefundable();
        poolManager.take(imd, address(this), amount);
        poolManager.sync(imd);
        imd.transfer(address(poolManager), amount);
        // The amount settled is the balance difference `sync` measures, which is exactly `amount`.
        // forge-lint: disable-next-line(unused-return)
        poolManager.settleFor(router);
        emit FeeRefunded(amount);
    }

    /// @dev The fee `beforeSwap` declares when IMD is the specified currency: what a full fill owes,
    /// clamped to the delta range so an oversized request is left to the pool to cap.
    function _declaredFee(SwapParams calldata params) internal pure returns (uint256 fee) {
        uint256 amount = _abs(params.amountSpecified);
        fee = params.amountSpecified < 0 ? amount / EXACT_INPUT_FEE_DIVISOR : amount / EXACT_OUTPUT_FEE_DIVISOR;
        if (fee > MAX_DELTA) fee = MAX_DELTA;
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

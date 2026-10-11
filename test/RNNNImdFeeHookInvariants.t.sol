// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";

import {RNNNImdFeeHook} from "../src/RNNNImdFeeHook.sol";
import {RNNNToken} from "../src/RNNNToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ActualDeltaRouter} from "./mocks/ActualDeltaRouter.sol";
import {RNNNImdFixture} from "./utils/RNNNImdFixture.sol";

/// @notice Drives the RNNN/IMD pool with random, bounded actions from several actors: all four swap
/// shapes, with and without a price limit that stops the pool short, liquidity in and out, donations,
/// gifted ERC-6909 claims and `collectPending`. Every action checks the hook's local promise (the fee
/// for this swap is exactly floor(1%) of the IMD the pool traded, capped at what `beforeSwap` declared;
/// the swapper's IMD moves by that leg plus or minus the fee; the hook keeps nothing; liquidity and
/// donations pay nothing) and records ghost totals for the invariants.
/// @dev Handler calls must not revert: the suites run with `fail-on-revert`, so a revert is a finding.
/// The one revert the hook documents, `ShortFillNotRefundable`, is caught and checked against its
/// stated precondition instead.
contract FeeHookHandler is Test {
    using StateLibrary for IPoolManager;

    address constant FEE_RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;
    int24 constant MIN_TICK = -887_220;
    int24 constant MAX_TICK = 887_220;
    int24 constant TICK_SPACING = 60;
    /// @dev Per-swap ceiling. Against 1e6 ether of base liquidity a swap this size always fills in full
    /// on the funded pool when it carries no price limit.
    uint256 constant MAX_SWAP = 10_000 ether;
    uint256 constant MAX_LIQUIDITY = 1_000 ether;

    PoolManager public manager;
    PoolSwapTest public swapRouter;
    ActualDeltaRouter public actualRouter;
    PoolModifyLiquidityTestNoChecks public lpRouter;
    PoolDonateTest public donateRouter;
    PoolClaimsTest public claimsRouter;
    RNNNToken public rnnn;
    MockERC20 public imd;
    RNNNImdFeeHook public hook;
    PoolKey public key;
    bool public imdIsCurrency0;

    address[] public actors;
    mapping(address actor => uint256 liquidity) public liquidityOf;

    // ---- ghost state ----
    /// @dev Everything the hook ever took as a fee: delivered to the recipient or held as a claim.
    uint256 public ghost_feesTaken;
    /// @dev The independent floor(1%) of each swap's pool leg (capped at the declaration where IMD was
    /// specified), summed; and the legs themselves.
    uint256 public ghost_expectedFees;
    uint256 public ghost_imdVolume;
    /// @dev Swaps the pool filled only partly and the hook trued up, and what it handed back on them.
    uint256 public ghost_shortFills;
    uint256 public ghost_refunded;
    /// @dev Swaps the hook refused with `ShortFillNotRefundable`.
    uint256 public ghost_refusedSwaps;
    uint256 public ghost_claimsGifted;
    uint256 public ghost_collected;
    uint256 public ghost_imdDonated;
    uint256 public ghost_swaps;
    mapping(bytes32 => uint256) public calls;

    modifier countCall(bytes32 name) {
        calls[name]++;
        _;
    }

    constructor(
        PoolManager manager_,
        PoolSwapTest swapRouter_,
        ActualDeltaRouter actualRouter_,
        PoolModifyLiquidityTestNoChecks lpRouter_,
        PoolDonateTest donateRouter_,
        PoolClaimsTest claimsRouter_,
        RNNNToken rnnn_,
        MockERC20 imd_,
        RNNNImdFeeHook hook_,
        PoolKey memory key_,
        address[] memory actors_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        actualRouter = actualRouter_;
        lpRouter = lpRouter_;
        donateRouter = donateRouter_;
        claimsRouter = claimsRouter_;
        rnnn = rnnn_;
        imd = imd_;
        hook = hook_;
        key = key_;
        imdIsCurrency0 = Currency.unwrap(key_.currency0) == address(imd_);
        actors = actors_;
    }

    // ------------------------------------------------------------------ swaps

    /// @notice Exact-input buy: spend `amount` IMD. IMD is the specified currency, so `beforeSwap` declares
    /// 1/101 of it and `afterSwap` trues that up to the fill. `spacings` sets a price limit that many tick
    /// spacings away (0: none), so the pool may stop short.
    function buyExactIn(uint256 actorSeed, uint256 amount, uint8 spacings) external countCall("buyExactIn") {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, _min(MAX_SWAP, imd.balanceOf(actor)));
        if (amount == 0) return;
        spacings = uint8(bound(spacings, 0, 40));

        Books memory a = _books(actor);
        bool ok = _swapSpecified(actor, imdIsCurrency0, -int256(amount), spacings, amount);
        Books memory b = _books(actor);
        if (!ok) return;

        uint256 fee = _feeTaken(a, b);
        uint256 leg = _poolImdLeg(a, b, true);
        uint256 paid = a.actorImd - b.actorImd;
        assertLe(paid, amount, "the swapper never pays more IMD than specified");
        assertGe(b.actorRnnn, a.actorRnnn, "a buy never takes RNNN from the swapper");
        _checkSwap(fee, leg, _declared(-int256(amount)), paid, true);
        if (paid < amount) _recordShortFill(_declared(-int256(amount)) - fee);
        else assertEq(leg + fee, amount, "a full fill uses the whole input: leg plus fee");
    }

    /// @notice Exact-output buy: receive `rnnnOut` RNNN. IMD is unspecified, so the fee is 1% of the IMD
    /// the pool quoted, charged on top.
    function buyExactOut(uint256 actorSeed, uint256 rnnnOut) external countCall("buyExactOut") {
        address actor = _actor(actorSeed);
        rnnnOut = bound(rnnnOut, 1, MAX_SWAP);

        Books memory a = _books(actor);
        BalanceDelta delta = _swapUnspecified(actor, imdIsCurrency0, int256(rnnnOut));
        Books memory b = _books(actor);

        uint256 fee = _feeTaken(a, b);
        uint256 leg = _poolImdLeg(a, b, true);
        assertLe(uint256(_rnnnDelta(delta)), rnnnOut, "the swapper never receives more RNNN than asked");
        _checkSwap(fee, leg, type(uint256).max, a.actorImd - b.actorImd, true);
    }

    /// @notice Exact-input sell: spend `rnnnIn` RNNN. IMD is unspecified; the swapper receives the pool's
    /// IMD output less 1%.
    function sellExactIn(uint256 actorSeed, uint256 rnnnIn) external countCall("sellExactIn") {
        address actor = _actor(actorSeed);
        // Sell no more than the pool can plausibly pay for: once the pool's IMD is gone the price slides
        // to the tick limit with nothing traded, and the next sell would hit PriceLimitAlreadyExceeded
        // (a v4 property, not the hook's).
        uint256 deliverable = _imdThePoolCanReturn() / 4;
        if (deliverable == 0 || _priceAtLimit(!imdIsCurrency0)) return;
        rnnnIn = bound(rnnnIn, 1, _min(_min(MAX_SWAP, deliverable), rnnn.balanceOf(actor)));

        Books memory a = _books(actor);
        BalanceDelta delta = _swapUnspecified(actor, !imdIsCurrency0, -int256(rnnnIn));
        Books memory b = _books(actor);

        uint256 fee = _feeTaken(a, b);
        uint256 leg = _poolImdLeg(a, b, false);
        assertLe(uint256(-_rnnnDelta(delta)), rnnnIn, "the swapper never spends more RNNN than specified");
        _checkSwap(fee, leg, type(uint256).max, b.actorImd - a.actorImd, false);
    }

    /// @notice Exact-output sell: receive `imdOut` IMD. IMD is specified; `beforeSwap` declares 1/99 of it
    /// and `afterSwap` trues that up to the fill. `spacings` sets a price limit (0: none).
    function sellExactOut(uint256 actorSeed, uint256 imdOut, uint8 spacings) external countCall("sellExactOut") {
        address actor = _actor(actorSeed);
        uint256 deliverable = _imdThePoolCanReturn() / 4;
        if (deliverable == 0 || _priceAtLimit(!imdIsCurrency0)) return;
        imdOut = bound(imdOut, 1, _min(MAX_SWAP, deliverable));
        spacings = uint8(bound(spacings, 0, 40));

        Books memory a = _books(actor);
        bool ok = _swapSpecified(actor, !imdIsCurrency0, int256(imdOut), spacings, rnnn.balanceOf(actor));
        Books memory b = _books(actor);
        if (!ok) return;

        uint256 fee = _feeTaken(a, b);
        uint256 leg = _poolImdLeg(a, b, false);
        uint256 received = b.actorImd - a.actorImd;
        assertLe(received, imdOut, "the swapper never receives more IMD than asked");
        assertLe(b.actorRnnn, a.actorRnnn, "a sell never pays the swapper RNNN");
        _checkSwap(fee, leg, _declared(int256(imdOut)), received, false);
        if (received < imdOut) _recordShortFill(_declared(int256(imdOut)) - fee);
        else assertEq(leg, imdOut + fee, "a full fill pays out the whole output plus the fee");
    }

    // ------------------------------------------------------------------ liquidity and the manager's balance

    function addLiquidity(uint256 actorSeed, uint256 liquidity) external countCall("addLiquidity") {
        address actor = _actor(actorSeed);
        liquidity = bound(liquidity, 1e15, MAX_LIQUIDITY);
        uint256 feesBefore = _feesInSystem();

        vm.prank(actor);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(liquidity), bytes32(uint256(uint160(actor)))), ""
        );
        liquidityOf[actor] += liquidity;

        assertEq(_feesInSystem(), feesBefore, "adding liquidity pays no fee");
        _assertHookHoldsNothing();
    }

    function removeLiquidity(uint256 actorSeed, uint256 liquidity) external countCall("removeLiquidity") {
        address actor = _actor(actorSeed);
        if (liquidityOf[actor] == 0) return;
        liquidity = bound(liquidity, 1, liquidityOf[actor]);
        uint256 feesBefore = _feesInSystem();

        vm.prank(actor);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, -int256(liquidity), bytes32(uint256(uint160(actor)))), ""
        );
        liquidityOf[actor] -= liquidity;

        assertEq(_feesInSystem(), feesBefore, "removing liquidity pays no fee");
        _assertHookHoldsNothing();
    }

    /// @notice A donation puts IMD and RNNN into the manager without a swap: the hook must not treat it as
    /// a fee, and its `available` check sees a larger balance afterwards.
    function donate(uint256 amount0, uint256 amount1) external countCall("donate") {
        if (IPoolManager(address(manager)).getLiquidity(PoolId.wrap(keccak256(abi.encode(key)))) == 0) return;
        amount0 = bound(amount0, 0, 100 ether);
        amount1 = bound(amount1, 0, 100 ether);
        if (amount0 == 0 && amount1 == 0) amount0 = 1;
        uint256 feesBefore = _feesInSystem();

        donateRouter.donate(key, amount0, amount1, "");
        ghost_imdDonated += imdIsCurrency0 ? amount0 : amount1;

        assertEq(_feesInSystem(), feesBefore, "a donation pays no fee");
        _assertHookHoldsNothing();
    }

    /// @notice Anyone can hand the hook an ERC-6909 IMD claim. It must count as pending and reach the
    /// recipient, never anyone else.
    function giftClaim(uint256 actorSeed, uint256 amount) external countCall("giftClaim") {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, _min(100 ether, imd.balanceOf(actor)));
        if (amount == 0) return;
        uint256 pendingBefore = hook.pendingFees();

        vm.startPrank(actor);
        claimsRouter.deposit(Currency.wrap(address(imd)), actor, amount);
        manager.transfer(address(hook), uint256(uint160(address(imd))), amount);
        vm.stopPrank();
        ghost_claimsGifted += amount;

        assertEq(hook.pendingFees(), pendingBefore + amount, "a gifted claim shows as pending");
    }

    function collectPending(uint256 actorSeed) external countCall("collectPending") {
        address actor = _actor(actorSeed);
        uint256 pendingBefore = hook.pendingFees();
        uint256 available = imd.balanceOf(address(manager));
        uint256 recipientBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 actorBefore = imd.balanceOf(actor);

        vm.prank(actor);
        uint256 paid = hook.collectPending();
        ghost_collected += paid;

        assertEq(paid, _min(pendingBefore, available), "collectPending delivers as much as the manager holds");
        assertEq(imd.balanceOf(FEE_RECIPIENT), recipientBefore + paid, "delivered to the fixed recipient");
        assertEq(hook.pendingFees(), pendingBefore - paid, "the claim shrinks by what was delivered");
        assertEq(imd.balanceOf(actor), actorBefore, "the caller gets nothing");
        _assertHookHoldsNothing();
    }

    // ------------------------------------------------------------------ views for the invariants

    function feesInSystem() external view returns (uint256) {
        return _feesInSystem();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ internals

    struct Books {
        uint256 actorImd;
        uint256 actorRnnn;
        uint256 managerImd;
        uint256 recipientImd;
        uint256 recipientRnnn;
        uint256 pending;
    }

    function _books(address actor) internal view returns (Books memory b) {
        b.actorImd = imd.balanceOf(actor);
        b.actorRnnn = rnnn.balanceOf(actor);
        b.managerImd = imd.balanceOf(address(manager));
        b.recipientImd = imd.balanceOf(FEE_RECIPIENT);
        b.recipientRnnn = rnnn.balanceOf(FEE_RECIPIENT);
        b.pending = hook.pendingFees();
    }

    /// @dev A swap whose IMD side is the unspecified currency, through v4-core's router: no refund can be
    /// needed, so it always completes.
    function _swapUnspecified(address actor, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        SwapParams memory params = SwapParams(zeroForOne, amountSpecified, _limit(zeroForOne, 0));
        vm.prank(actor);
        delta = swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        ghost_swaps++;
    }

    /// @dev A swap whose IMD side is the specified currency, through the router that settles recorded
    /// deltas, so a short fill's refund reaches it. Returns false when the hook refused the swap with
    /// `ShortFillNotRefundable`; that is only allowed when the manager held less IMD than the declared
    /// fee, the one case the refund cannot be sourced, and then nothing may have moved.
    function _swapSpecified(address actor, bool zeroForOne, int256 amountSpecified, uint8 spacings, uint256 maxIn)
        internal
        returns (bool ok)
    {
        SwapParams memory params = SwapParams(zeroForOne, amountSpecified, _limit(zeroForOne, spacings));
        Books memory a = _books(actor);
        vm.prank(actor);
        try actualRouter.swap(key, params, maxIn) {
            ok = true;
        } catch (bytes memory reason) {
            bytes memory expected = abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(RNNNImdFeeHook.ShortFillNotRefundable.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            );
            assertEq(keccak256(reason), keccak256(expected), "the only revert a swap may see is ShortFillNotRefundable");
            assertLt(
                a.managerImd, _declared(amountSpecified), "refused only when the manager cannot cover the declaration"
            );
            Books memory b = _books(actor);
            assertEq(a.actorImd, b.actorImd, "a refused swap moves no IMD");
            assertEq(a.actorRnnn, b.actorRnnn, "a refused swap moves no RNNN");
            assertEq(a.pending, b.pending, "a refused swap books nothing");
            assertEq(a.recipientImd, b.recipientImd);
            ghost_refusedSwaps++;
        }
        ghost_swaps++;
    }

    /// @dev The checks every completed swap must pass, computed from balances alone: the fee this swap put
    /// in the system is floor(1%) of the IMD the pool traded (never above the `beforeSwap` declaration
    /// when IMD was specified), the swapper's IMD moved by the leg plus (buy) or minus (sell) that fee,
    /// the recipient saw no RNNN and the hook holds nothing.
    function _checkSwap(uint256 fee, uint256 leg, uint256 declared, uint256 actorImdMoved, bool isBuy) internal {
        uint256 onePercent = leg / 100;
        uint256 expected = onePercent < declared ? onePercent : declared;
        assertEq(fee, expected, "fee is exactly floor(1%) of the IMD the pool traded, capped at the declaration");
        assertLe(onePercent - fee, 1, "never more than one wei under 1% of the leg");
        if (isBuy) assertEq(actorImdMoved, leg + fee, "a buyer pays the pool's leg plus the fee");
        else assertEq(actorImdMoved, leg - fee, "a seller receives the pool's leg minus the fee");
        ghost_feesTaken += fee;
        ghost_expectedFees += expected;
        ghost_imdVolume += leg;
        assertEq(rnnn.balanceOf(FEE_RECIPIENT), 0, "the recipient is never paid in RNNN");
        _assertHookHoldsNothing();
    }

    function _recordShortFill(uint256 refunded) internal {
        ghost_shortFills++;
        ghost_refunded += refunded;
    }

    /// @dev The fee the hook declares when IMD is specified, from the README's rule: 1/101 of an exact
    /// input, 1/99 of an exact output.
    function _declared(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified < 0 ? uint256(-amountSpecified) / 101 : uint256(amountSpecified) / 99;
    }

    /// @dev Fee this swap added to the system: delivered to the recipient or booked as a claim.
    function _feeTaken(Books memory a, Books memory b) internal pure returns (uint256) {
        return (b.recipientImd + b.pending) - (a.recipientImd + a.pending);
    }

    /// @dev The IMD the pool itself traded, read from balances: all IMD leaving the manager goes to the
    /// recipient (this fee or an older claim delivered along) or the swapper, and a claim minted or
    /// burned moves the books without moving IMD. So for a buy the leg is the manager's gain less the
    /// change in pending claims, and for a sell the manager's loss plus it.
    function _poolImdLeg(Books memory a, Books memory b, bool isBuy) internal pure returns (uint256) {
        int256 managerDelta = int256(b.managerImd) - int256(a.managerImd);
        int256 pendingDelta = int256(b.pending) - int256(a.pending);
        int256 leg = isBuy ? managerDelta - pendingDelta : pendingDelta - managerDelta;
        assertGe(leg, 0, "a pool leg is never negative");
        return uint256(leg);
    }

    /// @dev A price limit `spacings` tick spacings past the current price, or the furthest one when 0.
    function _limit(bool zeroForOne, uint8 spacings) internal view returns (uint160) {
        if (spacings == 0) return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        int24 target =
            zeroForOne ? tick - int24(uint24(spacings)) * TICK_SPACING : tick + int24(uint24(spacings)) * TICK_SPACING;
        if (target < TickMath.MIN_TICK + 1) target = TickMath.MIN_TICK + 1;
        if (target > TickMath.MAX_TICK - 1) target = TickMath.MAX_TICK - 1;
        return TickMath.getSqrtPriceAtTick(target);
    }

    /// @dev An upper estimate of the IMD swappable out of the pool: what the manager holds less claims
    /// and donations (LP fees accrued to positions are also unswappable, hence callers divide further).
    function _imdThePoolCanReturn() internal view returns (uint256) {
        uint256 inManager = imd.balanceOf(address(manager));
        uint256 locked = hook.pendingFees() + ghost_imdDonated;
        return inManager > locked ? inManager - locked : 0;
    }

    /// @dev True when the pool's price already sits at the limit a swap in `zeroForOne` would use.
    function _priceAtLimit(bool zeroForOne) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        return zeroForOne ? sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE + 1 : sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev Delivered plus pending: the only two places a fee can be.
    function _feesInSystem() internal view returns (uint256) {
        return imd.balanceOf(FEE_RECIPIENT) + hook.pendingFees();
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(imd.balanceOf(address(hook)), 0, "the hook never holds IMD");
        assertEq(rnnn.balanceOf(address(hook)), 0, "the hook never holds RNNN");
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int256) {
        return imdIsCurrency0 ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function _rnnnDelta(BalanceDelta delta) internal view returns (int256) {
        return imdIsCurrency0 ? int256(delta.amount1()) : int256(delta.amount0());
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @notice Common wiring for both invariant suites.
abstract contract RNNNImdFeeHookInvariantBase is RNNNImdFixture {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    PoolSwapTest swapRouter;
    ActualDeltaRouter actualRouter;
    PoolModifyLiquidityTestNoChecks lpRouter;
    PoolDonateTest donateRouter;
    PoolClaimsTest claimsRouter;
    RNNNToken rnnn;
    MockERC20 imd;
    RNNNImdFeeHook hook;
    PoolKey key;
    bool imdIsCurrency0;
    FeeHookHandler handler;

    uint256 constant ACTOR_FUNDS = 100_000_000 ether;

    function _deployWorld(bool imdBelow) internal {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        actualRouter = new ActualDeltaRouter(manager);
        lpRouter = new PoolModifyLiquidityTestNoChecks(manager);
        donateRouter = new PoolDonateTest(manager);
        claimsRouter = new PoolClaimsTest(manager);
        rnnn = new RNNNToken();
        imd = deployImdOrdered(address(rnnn), imdBelow, 1_000_000_000 ether);
        hook = deployHook(manager, address(imd), FEE_RECIPIENT);
        key = poolKeyFor(address(rnnn), address(imd), IHooks(address(hook)));
        imdIsCurrency0 = Currency.unwrap(key.currency0) == address(imd);
        assertEq(imdIsCurrency0, imdBelow, "ordering as requested");

        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1_1);

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        address[] memory spenders = new address[](5);
        spenders[0] = address(swapRouter);
        spenders[1] = address(lpRouter);
        spenders[2] = address(donateRouter);
        spenders[3] = address(claimsRouter);
        spenders[4] = address(actualRouter);
        for (uint256 i = 0; i < actors.length; i++) {
            imd.mint(actors[i], ACTOR_FUNDS);
            rnnn.transfer(actors[i], ACTOR_FUNDS);
            approveAll(actors[i], rnnn, imd, spenders);
        }
        approveAll(address(this), rnnn, imd, spenders);

        handler = new FeeHookHandler(
            manager, swapRouter, actualRouter, lpRouter, donateRouter, claimsRouter, rnnn, imd, hook, key, actors
        );
        imd.mint(address(handler), ACTOR_FUNDS);
        rnnn.transfer(address(handler), ACTOR_FUNDS);
        approveAll(address(handler), rnnn, imd, spenders);

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------ invariants

    /// @notice Every fee the hook ever took is either with the recipient or still pending as a claim, and
    /// nothing else ever lands there: gifted claims included, nothing lost, nothing created.
    function invariant_everyFeeIsWithTheRecipientOrPending() public view {
        assertEq(
            imd.balanceOf(FEE_RECIPIENT) + hook.pendingFees(),
            handler.ghost_feesTaken() + handler.ghost_claimsGifted(),
            "recipient + pending != fees taken + claims gifted"
        );
    }

    /// @notice Over every swap that went through, full or short, the fees sum to exactly the floor(1%) of
    /// each swap's pool leg (capped at the `beforeSwap` declaration where IMD was specified), computed
    /// independently in the handler from balances; never a wei more than 1% of the IMD volume.
    function invariant_feesAreExactlyOnePercentOfTradedVolume() public view {
        assertEq(handler.ghost_feesTaken(), handler.ghost_expectedFees(), "sum of floor(1%) of each pool leg");
        assertLe(handler.ghost_feesTaken(), handler.ghost_imdVolume() / 100, "never above 1% of the IMD traded");
    }

    /// @notice A short fill hands the unowed part of the declaration back, and the hook keeps none of it:
    /// what was refunded never shows up with the recipient, as a claim, or with the hook.
    function invariant_refundsNeverReachTheRecipientOrStayWithTheHook() public view {
        assertEq(
            imd.balanceOf(FEE_RECIPIENT) + hook.pendingFees(),
            handler.ghost_feesTaken() + handler.ghost_claimsGifted(),
            "a refund leaked into the fees"
        );
        assertEq(imd.balanceOf(address(actualRouter)), 0, "the router holds IMD after a swap");
        assertEq(rnnn.balanceOf(address(actualRouter)), 0, "the router holds RNNN after a swap");
        assertEq(imd.balanceOf(address(hook)), 0, "the hook holds the refund");
    }

    /// @notice The hook never ends up holding tokens itself; fees live in the manager as claims or go out.
    function invariant_hookHoldsNoTokens() public view {
        assertEq(imd.balanceOf(address(hook)), 0, "hook holds IMD");
        assertEq(rnnn.balanceOf(address(hook)), 0, "hook holds RNNN");
        assertEq(address(hook).balance, 0, "hook holds ETH");
    }

    /// @notice The recipient is paid in IMD and only IMD.
    function invariant_recipientNeverReceivesRnnn() public view {
        assertEq(rnnn.balanceOf(FEE_RECIPIENT), 0, "the recipient received RNNN");
        assertEq(rnnn.balanceOf(FEE_RECIPIENT), 0);
    }

    /// @notice Pending claims are always redeemable: the manager holds at least that much IMD.
    function invariant_pendingClaimsAreBackedByTheManager() public view {
        assertGe(imd.balanceOf(address(manager)), hook.pendingFees(), "a claim the manager cannot honour");
    }

    /// @notice Nothing in any sequence changes what the hook is configured to do.
    function invariant_configurationNeverChanges() public view {
        assertEq(hook.feeRecipient(), FEE_RECIPIENT);
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.FEE_BPS(), 100);
    }

    /// @notice The manager is never left locked or in debt by the hook: the pool keeps working.
    function invariant_poolStillQuotesAPrice() public view {
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        assertGt(sqrtPriceX96, 0, "the pool lost its price");
    }
}

/// @notice The pool as it looks after launch: liquidity on both sides, every fee deliverable at once.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract RNNNImdFeeHookFundedPoolInvariants is RNNNImdFeeHookInvariantBase {
    function setUp() public {
        _deployWorld(true);
        addFullRange(lpRouter, key, address(this), int256(1_000_000 ether));
    }

    /// @notice On a funded pool the manager always holds more IMD than any declaration the handler's bounds
    /// can produce, so the refund is always sourceable: no swap is ever refused, short fills included.
    function invariant_fundedPoolNeverRefusesASwap() public view {
        assertEq(handler.ghost_refusedSwaps(), 0, "a swap on a funded pool was refused");
    }

    /// @notice On a funded pool no fee is ever deferred: every fee reaches the recipient in its own swap, so
    /// whatever is pending at any point can only be claims strangers gifted and nobody has collected yet.
    function invariant_fundedPoolDefersNoFee() public view {
        assertLe(hook.pendingFees(), handler.ghost_claimsGifted(), "a fee was deferred on a funded pool");
    }
}

/// @notice The pool at launch: RNNN-only liquidity and no IMD in the manager until the first buy settles,
/// with IMD as currency1 this time. Fees defer to claims and are delivered later.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract RNNNImdFeeHookFreshPoolInvariants is RNNNImdFeeHookInvariantBase {
    function setUp() public {
        _deployWorld(false);
        addRnnnOnly(lpRouter, key, imdIsCurrency0, address(this), 1_000_000 ether);
        assertEq(imd.balanceOf(address(manager)), 0, "the manager starts with no IMD");
    }
}

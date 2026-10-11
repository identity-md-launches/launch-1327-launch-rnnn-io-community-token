// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {RNNNImdFixture} from "./utils/RNNNImdFixture.sol";

/// @notice Drives the RNNN/IMD pool with random, bounded actions from several actors: all four swap
/// shapes, liquidity in and out, donations, gifted ERC-6909 claims and `collectPending`. Every action
/// checks the hook's local promise (the fee for this swap is exactly floor(1%) of its IMD side, the hook
/// keeps nothing, liquidity and donations pay nothing) and records ghost totals for the invariants.
/// @dev Handler calls must not revert: the suites run with `fail-on-revert`, so a revert is a finding.
contract FeeHookHandler is Test {
    using StateLibrary for IPoolManager;

    address constant FEE_RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;
    int24 constant MIN_TICK = -887_220;
    int24 constant MAX_TICK = 887_220;
    /// @dev Per-swap ceiling. Against 1e6 ether of base liquidity a swap this size always fills in full
    /// on the funded pool, so the exact-1% assertion is never skipped there.
    uint256 constant MAX_SWAP = 10_000 ether;
    uint256 constant MAX_LIQUIDITY = 1_000 ether;

    PoolManager public manager;
    PoolSwapTest public swapRouter;
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
    /// @dev Fees on swaps the pool filled completely, and the independent floor(1%) each should have been.
    uint256 public ghost_feesOnFullFills;
    uint256 public ghost_expectedFeesOnFullFills;
    uint256 public ghost_imdVolumeOnFullFills;
    /// @dev Swaps the pool filled only partly. The fee on those is a reported defect (see
    /// .imd-findings.json), so they are counted here and excluded from the exact-1% check.
    uint256 public ghost_partialFills;
    uint256 public ghost_overchargeOnPartialFills;
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

    /// @notice Exact-input buy: spend `amount` IMD. IMD is the specified currency, so the fee is declared
    /// in beforeSwap and the swapper pays exactly what they specified.
    function buyExactIn(uint256 actorSeed, uint256 amount) external countCall("buyExactIn") {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, _min(MAX_SWAP, imd.balanceOf(actor)));
        if (amount == 0) return;

        (BalanceDelta delta, uint256 fee) = _swap(actor, imdIsCurrency0, -int256(amount));
        int256 imdDelta = _imdDelta(delta);
        assertLe(imdDelta, 0, "a buy never pays the swapper IMD");
        assertGe(_rnnnDelta(delta), 0, "a buy never takes RNNN from the swapper");
        uint256 paid = uint256(-imdDelta);
        assertLe(paid, amount, "the swapper never pays more IMD than specified");

        if (paid == amount) {
            _recordFullFill(fee, amount);
        } else {
            _recordPartialFill(fee, paid);
        }
    }

    /// @notice Exact-output buy: receive `rnnnOut` RNNN. IMD is unspecified, so the fee is 1% of the IMD
    /// the pool quoted, charged on top.
    function buyExactOut(uint256 actorSeed, uint256 rnnnOut) external countCall("buyExactOut") {
        address actor = _actor(actorSeed);
        rnnnOut = bound(rnnnOut, 1, MAX_SWAP);

        (BalanceDelta delta, uint256 fee) = _swap(actor, imdIsCurrency0, int256(rnnnOut));
        int256 imdDelta = _imdDelta(delta);
        assertLe(imdDelta, 0, "a buy never pays the swapper IMD");
        uint256 paid = uint256(-imdDelta);
        assertGe(paid, fee, "the fee is part of what the swapper paid");
        uint256 pooled = paid - fee;
        // The hook measured the pool's own IMD delta, so this holds whether or not the fill was complete.
        assertEq(fee, pooled / 100, "exact-output buy: fee is floor(1%) of the IMD the pool quoted");
        assertLe(uint256(_rnnnDelta(delta)), rnnnOut, "the swapper never receives more RNNN than asked");
        _recordFullFill(fee, pooled);
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

        (BalanceDelta delta, uint256 fee) = _swap(actor, !imdIsCurrency0, -int256(rnnnIn));
        int256 imdDelta = _imdDelta(delta);
        assertGe(imdDelta, 0, "an exact-input sell never charges the swapper IMD");
        uint256 received = uint256(imdDelta);
        uint256 pooledOut = received + fee;
        assertEq(fee, pooledOut / 100, "exact-input sell: fee is floor(1%) of the IMD the pool paid out");
        assertLe(uint256(-_rnnnDelta(delta)), rnnnIn, "the swapper never spends more RNNN than specified");
        _recordFullFill(fee, pooledOut);
    }

    /// @notice Exact-output sell: receive `imdOut` IMD. IMD is specified; the pool pays out 1% more and the
    /// swapper receives exactly what they asked for.
    /// @dev Bounded to a quarter of the IMD the pool can plausibly return so the fill is complete; a fill
    /// that is still partial is recorded, not asserted (reported defect).
    function sellExactOut(uint256 actorSeed, uint256 imdOut) external countCall("sellExactOut") {
        address actor = _actor(actorSeed);
        uint256 deliverable = _imdThePoolCanReturn() / 4;
        if (deliverable == 0 || _priceAtLimit(!imdIsCurrency0)) return;
        imdOut = bound(imdOut, 1, _min(MAX_SWAP, deliverable));

        (BalanceDelta delta, uint256 fee) = _swap(actor, !imdIsCurrency0, int256(imdOut));
        int256 imdDelta = _imdDelta(delta);
        assertLe(imdDelta, int256(imdOut), "the swapper never receives more IMD than asked");
        assertLe(_rnnnDelta(delta), 0, "a sell never pays the swapper RNNN");

        if (imdDelta == int256(imdOut)) {
            _recordFullFill(fee, imdOut);
        } else {
            _recordPartialFill(fee, imdDelta > 0 ? uint256(imdDelta) : 0);
        }
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

    function _swap(address actor, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta, uint256 fee)
    {
        uint256 feesBefore = _feesInSystem();
        uint256 recipientRnnnBefore = rnnn.balanceOf(FEE_RECIPIENT);

        delta = swapAs(actor, zeroForOne, amountSpecified);

        fee = _feesInSystem() - feesBefore;
        ghost_feesTaken += fee;
        ghost_swaps++;
        assertEq(rnnn.balanceOf(FEE_RECIPIENT), recipientRnnnBefore, "the recipient is never paid in RNNN");
        _assertHookHoldsNothing();
    }

    function swapAs(address actor, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams(
            zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.prank(actor);
        return swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    function _recordFullFill(uint256 fee, uint256 imdSide) internal {
        assertEq(fee, imdSide / 100, "fee is exactly floor(1%) of the swap's IMD side");
        ghost_feesOnFullFills += fee;
        ghost_expectedFeesOnFullFills += imdSide / 100;
        ghost_imdVolumeOnFullFills += imdSide;
    }

    function _recordPartialFill(uint256 fee, uint256 imdMoved) internal {
        ghost_partialFills++;
        uint256 fair = imdMoved / 100;
        if (fee > fair) ghost_overchargeOnPartialFills += fee - fair;
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
        address[] memory spenders = new address[](4);
        spenders[0] = address(swapRouter);
        spenders[1] = address(lpRouter);
        spenders[2] = address(donateRouter);
        spenders[3] = address(claimsRouter);
        for (uint256 i = 0; i < actors.length; i++) {
            imd.mint(actors[i], ACTOR_FUNDS);
            rnnn.transfer(actors[i], ACTOR_FUNDS);
            approveAll(actors[i], rnnn, imd, spenders);
        }
        approveAll(address(this), rnnn, imd, spenders);

        handler =
            new FeeHookHandler(manager, swapRouter, lpRouter, donateRouter, claimsRouter, rnnn, imd, hook, key, actors);
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

    /// @notice Over every completely filled swap, the fees sum to exactly the floor(1%) of each swap's IMD
    /// side, computed independently in the handler; never a wei more.
    function invariant_feesAreExactlyOnePercentOfFullyFilledVolume() public view {
        assertEq(handler.ghost_feesOnFullFills(), handler.ghost_expectedFeesOnFullFills(), "sum of floor(1%)");
        assertLe(handler.ghost_feesOnFullFills(), handler.ghost_imdVolumeOnFullFills() / 100, "never above 1%");
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

    /// @notice On a funded pool the handler's bounds keep every swap a complete fill, so the exact-1% rule
    /// is checked on every single swap in the run, and no fee is ever deferred for long.
    function invariant_fundedPoolNeverSeesAPartialFill() public view {
        assertEq(handler.ghost_partialFills(), 0, "a bounded swap on 1e6 ether of liquidity did not fill");
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

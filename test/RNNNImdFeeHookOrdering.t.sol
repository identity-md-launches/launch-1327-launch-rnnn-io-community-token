// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VmSafe} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";

import {RNNNImdFeeHook} from "../src/RNNNImdFeeHook.sol";
import {RNNNToken} from "../src/RNNNToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ActualDeltaRouter} from "./mocks/ActualDeltaRouter.sol";
import {RNNNImdFixture} from "./utils/RNNNImdFixture.sol";

/// @dev A recipient that refuses ETH outright. The fee is an ERC-20 transfer, so it must still be paid.
contract RejectsEth {
    receive() external payable {
        revert("no ETH");
    }
}

/// @notice The same assertions with IMD as currency0 and as currency1. Which side IMD lands on depends
/// on the two token addresses at launch, so the hook's side detection has to be right both ways; the
/// original suite only exercises whichever ordering its deployment happened to produce.
abstract contract RNNNImdFeeHookOrderingBehaviour is RNNNImdFixture {
    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTestNoChecks lpRouter;
    PoolClaimsTest claimsRouter;
    ActualDeltaRouter actualRouter;
    RNNNToken rnnn;
    MockERC20 imd;
    RNNNImdFeeHook hook;
    PoolKey key;
    bool imdIsCurrency0;

    address swapper = makeAddr("swapper");
    address stranger = makeAddr("stranger");

    /// @dev The fee a full-fill exact-input buy of 1,000 IMD owes: 1/101 of it, 1% of the pool's leg.
    uint256 constant FEE_ON_1000_IN = uint256(1_000 ether) / 101;

    function imdBelowRnnn() internal pure virtual returns (bool);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTestNoChecks(manager);
        claimsRouter = new PoolClaimsTest(manager);
        actualRouter = new ActualDeltaRouter(manager);
        rnnn = new RNNNToken();
        imd = deployImdOrdered(address(rnnn), imdBelowRnnn(), 1_000_000_000 ether);
        hook = deployHook(manager, address(imd), FEE_RECIPIENT);
        key = poolKeyFor(address(rnnn), address(imd), IHooks(address(hook)));
        imdIsCurrency0 = Currency.unwrap(key.currency0) == address(imd);
        assertEq(imdIsCurrency0, imdBelowRnnn(), "the ordering under test");

        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1_1);

        address[] memory spenders = new address[](4);
        spenders[0] = address(swapRouter);
        spenders[1] = address(lpRouter);
        spenders[2] = address(claimsRouter);
        spenders[3] = address(actualRouter);
        approveAll(address(this), rnnn, imd, spenders);
        imd.mint(swapper, 10_000_000 ether);
        rnnn.transfer(swapper, 10_000_000 ether);
        approveAll(swapper, rnnn, imd, spenders);
        imd.mint(stranger, 1_000_000 ether);
        approveAll(stranger, rnnn, imd, spenders);
    }

    function seedBothSides() internal {
        addFullRange(lpRouter, key, address(this), int256(1_000_000 ether));
    }

    function seedRnnnOnly() internal {
        addRnnnOnly(lpRouter, key, imdIsCurrency0, address(this), 1_000_000 ether);
        assertEq(imd.balanceOf(address(manager)), 0, "no IMD in the manager yet");
    }

    function buy(int256 amountSpecified) internal returns (BalanceDelta) {
        return swapAs(swapRouter, key, swapper, imdIsCurrency0, amountSpecified);
    }

    function sell(int256 amountSpecified) internal returns (BalanceDelta) {
        return swapAs(swapRouter, key, swapper, !imdIsCurrency0, amountSpecified);
    }

    function imdDelta(BalanceDelta d) internal view returns (int256) {
        return imdIsCurrency0 ? int256(d.amount0()) : int256(d.amount1());
    }

    function rnnnDelta(BalanceDelta d) internal view returns (int256) {
        return imdIsCurrency0 ? int256(d.amount1()) : int256(d.amount0());
    }

    function feesInSystem() internal view returns (uint256) {
        return imd.balanceOf(FEE_RECIPIENT) + hook.pendingFees();
    }

    /// @dev A price-limited swap through the actual-delta router, from `swapper`, with the limit `spacings`
    /// tick spacings from the current price.
    function limitedSwap(bool zeroForOne, int256 amountSpecified, int24 spacings, uint256 maxIn)
        internal
        returns (BalanceDelta)
    {
        return swapActualAs(
            actualRouter, key, swapper, limitedParams(manager, key, zeroForOne, amountSpecified, spacings), maxIn
        );
    }

    struct Snap {
        uint256 swapperImd;
        uint256 swapperRnnn;
        uint256 managerImd;
        uint256 recipientImd;
        uint256 pending;
    }

    function snap() internal view returns (Snap memory s) {
        s.swapperImd = imd.balanceOf(swapper);
        s.swapperRnnn = rnnn.balanceOf(swapper);
        s.managerImd = imd.balanceOf(address(manager));
        s.recipientImd = imd.balanceOf(FEE_RECIPIENT);
        s.pending = hook.pendingFees();
    }

    /// @dev The IMD the pool itself traded in the swap between two snapshots, read from balances alone:
    /// every IMD leaving the manager goes to the recipient (a fee, or an older claim delivered along) or
    /// the swapper, and a claim minted or burned moves the books without moving IMD. Independent of the
    /// hook's own arithmetic, so it can check it.
    function poolImdLeg(Snap memory a, Snap memory b, bool isBuy) internal pure returns (uint256) {
        int256 managerDelta = int256(b.managerImd) - int256(a.managerImd);
        int256 pendingDelta = int256(b.pending) - int256(a.pending);
        int256 leg = isBuy ? managerDelta - pendingDelta : pendingDelta - managerDelta;
        assertGe(leg, 0, "a leg is never negative");
        return uint256(leg);
    }

    /// @dev The fee the README's rule owes on a swap whose IMD leg was `leg`: 1% floor of it, but never
    /// more than `beforeSwap` declared when IMD was the specified currency.
    function feeOwed(uint256 leg, uint256 declared) internal pure returns (uint256) {
        uint256 onePercent = leg / 100;
        return onePercent < declared ? onePercent : declared;
    }

    // ------------------------------------------------------------------ the four swap shapes

    function test_buyExactInput_recipientGetsExactlyOnePercentOfTheImdSpent() public {
        seedBothSides();
        Snap memory a = snap();
        BalanceDelta d = buy(-int256(1_000 ether));
        Snap memory b = snap();
        assertEq(imdDelta(d), -int256(1_000 ether), "swapper paid exactly the IMD specified");
        assertGt(rnnnDelta(d), 0, "swapper received RNNN");
        uint256 fee = b.recipientImd - a.recipientImd;
        uint256 leg = poolImdLeg(a, b, true);
        assertEq(fee, FEE_ON_1000_IN, "1/101 of the 1,000 IMD spent: the fee a full fill owes");
        assertEq(fee, leg / 100, "which is exactly 1% of the IMD the pool traded");
        assertEq(leg + fee, 1_000 ether, "the 1,000 IMD is the pool's leg plus the fee, nothing else");
        assertEq(hook.pendingFees(), 0);
    }

    function test_buyExactOutput_recipientGetsExactlyOnePercentOfTheImdQuoted() public {
        seedBothSides();
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        uint256 managerBefore = imd.balanceOf(address(manager));
        BalanceDelta d = buy(int256(500 ether));
        uint256 fee = imd.balanceOf(FEE_RECIPIENT) - before;
        uint256 pooled = imd.balanceOf(address(manager)) - managerBefore;
        assertEq(rnnnDelta(d), int256(500 ether), "swapper received exactly the RNNN asked for");
        assertEq(uint256(-imdDelta(d)), pooled + fee, "swapper paid the pool's quote plus the fee");
        assertEq(fee, pooled / 100, "1% of the IMD the pool quoted");
        assertGt(fee, 0);
    }

    function test_sellExactInput_recipientGetsExactlyOnePercentOfTheImdOut() public {
        seedBothSides();
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        uint256 managerBefore = imd.balanceOf(address(manager));
        BalanceDelta d = sell(-int256(1_000 ether));
        uint256 fee = imd.balanceOf(FEE_RECIPIENT) - before;
        uint256 pooledOut = managerBefore - imd.balanceOf(address(manager));
        assertEq(rnnnDelta(d), -int256(1_000 ether), "swapper spent exactly the RNNN specified");
        assertEq(uint256(imdDelta(d)) + fee, pooledOut, "pool output = swapper output + fee");
        assertEq(fee, pooledOut / 100, "1% of the IMD side");
        assertGt(fee, 0);
    }

    function test_sellExactOutput_recipientGetsExactlyOnePercentOnTopOfTheImdDelivered() public {
        seedBothSides();
        Snap memory a = snap();
        BalanceDelta d = sell(int256(1_000 ether));
        Snap memory b = snap();
        uint256 fee = b.recipientImd - a.recipientImd;
        uint256 leg = poolImdLeg(a, b, false);
        assertEq(imdDelta(d), int256(1_000 ether), "swapper received exactly the IMD asked for");
        assertEq(fee, uint256(1_000 ether) / 99, "1/99 of the 1,000 IMD delivered: the fee a full fill owes");
        assertEq(fee, leg / 100, "which is exactly 1% of the IMD the pool paid out");
        assertEq(leg, 1_000 ether + fee, "the pool paid out the 1,000 IMD plus the fee");
        assertEq(a.managerImd - b.managerImd, 1_000 ether + fee, "both left the manager");
        assertLt(rnnnDelta(d), 0, "swapper paid RNNN");
    }

    /// @dev One property for all four shapes at random sizes: the fee leaving the system for this swap
    /// is floor(1%) of the IMD the pool traded (never above the fee `beforeSwap` declared when IMD was
    /// specified), the swapper's IMD moves by the pool's leg plus or minus that fee, and the hook keeps
    /// nothing.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_everySwapShapePaysFloorOnePercentOfItsImdSide(uint256 amount, uint8 shape) public {
        seedBothSides();
        amount = bound(amount, 1, 50_000 ether);
        shape = uint8(bound(shape, 0, 3));
        Snap memory a = snap();

        BalanceDelta d;
        if (shape == 0) d = buy(-int256(amount));
        else if (shape == 1) d = buy(int256(amount));
        else if (shape == 2) d = sell(-int256(amount));
        else d = sell(int256(amount));

        Snap memory b = snap();
        bool isBuy = shape < 2;
        uint256 fee = (b.recipientImd + b.pending) - (a.recipientImd + a.pending);
        uint256 leg = poolImdLeg(a, b, isBuy);
        // IMD is the specified currency on shapes 0 and 3; there the fee is capped at the declaration.
        uint256 declared =
            shape == 0 ? declaredFee(-int256(amount)) : shape == 3 ? declaredFee(int256(amount)) : type(uint256).max;
        assertEq(fee, feeOwed(leg, declared), "floor(1%) of the IMD the pool traded");
        assertGe(leg / 100, fee, "never above 1% of the pool's leg");
        assertLe(leg / 100 - fee, shape == 0 ? 1 : 0, "at most one wei under, and only on an exact-input buy");
        if (isBuy) assertEq(a.swapperImd - b.swapperImd, leg + fee, "a buyer pays the pool's leg plus the fee");
        else assertEq(b.swapperImd - a.swapperImd, leg - fee, "a seller receives the pool's leg minus the fee");
        if (shape == 0) assertEq(leg + fee, amount, "an exact input is used up entirely");
        if (shape == 3) assertEq(leg - fee, amount, "an exact output is delivered entirely");
        assertEq(b.pending, 0, "nothing deferred on a funded pool");
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(rnnn.balanceOf(address(hook)), 0);
        assertEq(rnnn.balanceOf(FEE_RECIPIENT), 0);
        if (shape == 0) assertEq(imdDelta(d), -int256(amount));
        if (shape == 3) assertEq(imdDelta(d), int256(amount));
    }

    // ------------------------------------------------------------------ rounding edges

    /// @dev The fee is a floor at every step: of the declaration (X/101, Y/99) and of 1% of the pool's leg.
    /// An exact input of 100 wei declares nothing, so the pool trades all 100 wei and no fee is taken even
    /// though 1% of that leg is 1 wei: the hook never charges more than it declared, one wei under is the
    /// price of that. 101 wei is the smallest exact-input buy that pays.
    function test_feeRoundsDownAtTheBoundary() public {
        seedBothSides();
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        buy(-99);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 0, "99 wei in: no fee");
        buy(-100);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 0, "100 wei in: declared 0, so no fee");
        buy(-101);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 1, "101 wei in: 1 wei, 1% of the 100 the pool traded");
        buy(-201);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 2, "201 wei in: still 1 wei");
        buy(-202);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 4, "202 wei in: 2 wei");
        sell(int256(98));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 4, "98 wei out: no fee");
        sell(int256(99));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 5, "99 wei out: 1 wei, 1% of the 100 the pool paid");
        sell(int256(197));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 6, "197 wei out: still 1 wei");
        sell(int256(198));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 8, "198 wei out: 2 wei");
    }

    // ------------------------------------------------------------------ short fills: the refund path

    /// @dev A buy whose price limit stops the pool early. `beforeSwap` declared 1/101 of the whole order;
    /// the pool traded less; the unowed part is handed back to the router inside the swap, so the swapper
    /// pays the fill plus 1% and nothing on the rest.
    function test_priceLimitedBuy_paysOnePercentOfTheFillAndRefundsTheRest() public {
        seedBothSides();
        uint256 requested = 100_000 ether;
        Snap memory a = snap();
        vm.recordLogs();
        limitedSwap(imdIsCurrency0, -int256(requested), 1, requested);
        Snap memory b = snap();

        uint256 fee = b.recipientImd - a.recipientImd;
        uint256 leg = poolImdLeg(a, b, true);
        assertLt(leg, requested / 2, "the limit stopped the fill well short of the order");
        assertGt(fee, 0);
        assertEq(fee, leg / 100, "1% of the IMD that traded, not of the order");
        assertEq(a.swapperImd - b.swapperImd, leg + fee, "the swapper paid the fill plus 1%, nothing on the rest");
        assertEq(imd.balanceOf(address(actualRouter)), 0, "the router kept nothing");
        assertEq(imd.balanceOf(address(hook)), 0, "the hook kept nothing");
        assertEq(b.pending, 0);

        uint256 refund = declaredFee(-int256(requested)) - fee;
        assertTrue(sawRefund(refund), "FeeRefunded carries exactly the unowed part of the declaration");
    }

    /// @dev The same on an exact-output sell: the seller receives the fill minus 1%, the pool pays nothing
    /// on the IMD it never delivered.
    function test_priceLimitedExactOutputSell_paysOnePercentOfTheFillAndRefundsTheRest() public {
        seedBothSides();
        uint256 requested = 100_000 ether;
        Snap memory a = snap();
        vm.recordLogs();
        limitedSwap(!imdIsCurrency0, int256(requested), 1, 1_000_000 ether);
        Snap memory b = snap();

        uint256 fee = b.recipientImd - a.recipientImd;
        uint256 leg = poolImdLeg(a, b, false);
        assertLt(leg, requested / 2, "the limit stopped the fill well short of the order");
        assertGt(fee, 0);
        assertEq(fee, leg / 100, "1% of the IMD that traded");
        assertEq(b.swapperImd - a.swapperImd, leg - fee, "the seller received the fill minus 1%");
        assertEq(rnnn.balanceOf(address(actualRouter)), 0, "the router returned the unused RNNN");
        assertEq(imd.balanceOf(address(actualRouter)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertTrue(sawRefund(declaredFee(int256(requested)) - fee), "FeeRefunded carries the unowed part");
    }

    /// @dev Short fills at random sizes and limits, both IMD-specified shapes: the fee is 1% of the fill,
    /// the swapper's IMD moves by the fill plus or minus it, and nobody else ends up holding anything.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_shortFillsPayOnePercentOfWhatTradedOnly(uint256 amount, uint8 spacings, bool isBuy) public {
        seedBothSides();
        amount = bound(amount, 1_000 ether, 5_000_000 ether);
        spacings = uint8(bound(spacings, 1, 40));
        Snap memory a = snap();
        if (isBuy) limitedSwap(imdIsCurrency0, -int256(amount), int24(uint24(spacings)), amount);
        else limitedSwap(!imdIsCurrency0, int256(amount), int24(uint24(spacings)), rnnn.balanceOf(swapper));
        Snap memory b = snap();

        uint256 fee = b.recipientImd - a.recipientImd;
        uint256 leg = poolImdLeg(a, b, isBuy);
        uint256 declared = declaredFee(isBuy ? -int256(amount) : int256(amount));
        assertEq(fee, feeOwed(leg, declared), "1% of what traded, capped at the declaration");
        if (isBuy) assertEq(a.swapperImd - b.swapperImd, leg + fee);
        else assertEq(b.swapperImd - a.swapperImd, leg - fee);
        assertEq(imd.balanceOf(address(actualRouter)), 0);
        assertEq(rnnn.balanceOf(address(actualRouter)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(b.pending, 0);
    }

    /// @dev v4-core's own test router settles the `BalanceDelta` the swap returned, which on a short fill
    /// is the pre-refund figure, so it cannot complete one: the hook's refund only reaches routers that
    /// settle the PoolManager's recorded delta (the Universal Router's `SETTLE_ALL`). A full fill through
    /// the same router is unaffected. This is the documented router caveat, pinned here so a change to it
    /// is noticed.
    function test_aRouterThatSettlesTheReturnedDeltaCannotCompleteAShortFill() public {
        seedBothSides();
        SwapParams memory params = limitedParams(manager, key, imdIsCurrency0, -int256(100_000 ether), 1);
        Snap memory a = snap();
        vm.prank(swapper);
        vm.expectRevert(
            bytes(
                imdIsCurrency0
                    ? "delta.amount0() is not equal to deltaAfter0"
                    : "delta.amount1() is not equal to deltaAfter1"
            )
        );
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        Snap memory b = snap();
        assertEq(a.swapperImd, b.swapperImd, "nothing moved");
        assertEq(a.recipientImd, b.recipientImd);
        // The same router completes a full fill.
        buy(-int256(1_000 ether));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - a.recipientImd, FEE_ON_1000_IN);
    }

    /// @dev The launch pool before its first buy settles holds no IMD, so a short fill's refund has nothing
    /// to draw on: the swap is refused outright rather than charged 1% of an order that did not trade.
    /// Nothing moves and nothing is booked for the recipient. Once a buy has settled, the same order fills
    /// short and is trued up.
    function test_shortFillIsRefusedWhileTheManagerHoldsNoImdAndTruedUpAfterwards() public {
        seedRnnnOnly();
        SwapParams memory params = limitedParams(manager, key, imdIsCurrency0, -int256(100_000 ether), 1);
        Snap memory a = snap();
        vm.prank(swapper);
        vm.expectRevert(wrappedAfterSwapRevert(address(hook), RNNNImdFeeHook.ShortFillNotRefundable.selector));
        actualRouter.swap(key, params, 100_000 ether);
        Snap memory b = snap();
        assertEq(a.swapperImd, b.swapperImd, "the swapper paid nothing");
        assertEq(a.swapperRnnn, b.swapperRnnn, "and received nothing");
        assertEq(b.pending, 0, "nothing booked for the recipient");
        assertEq(b.recipientImd, 0);

        buy(-int256(1_000 ether));
        a = snap();
        limitedSwap(imdIsCurrency0, -int256(100_000 ether), 1, 100_000 ether);
        b = snap();
        uint256 leg = poolImdLeg(a, b, true);
        uint256 delivered = b.recipientImd - a.recipientImd;
        // The earlier deferred claim rode along with this swap's fee.
        assertEq(b.pending, 0, "the claim from the first buy was delivered too");
        assertEq(delivered - a.pending, leg / 100, "this swap paid 1% of its fill");
        assertEq(a.swapperImd - b.swapperImd, leg + (delivered - a.pending), "the swapper paid the fill plus 1%");
    }

    /// @dev An exact-output sell on the launch pool can deliver no IMD at all: refused, not charged.
    function test_exactOutputSellThatFillsNothingIsRefused() public {
        seedRnnnOnly();
        Snap memory a = snap();
        vm.prank(swapper);
        vm.expectRevert(wrappedAfterSwapRevert(address(hook), RNNNImdFeeHook.ShortFillNotRefundable.selector));
        actualRouter.swap(
            key, SwapParams(!imdIsCurrency0, int256(1_000 ether), priceLimit(!imdIsCurrency0)), 1_000_000 ether
        );
        Snap memory b = snap();
        assertEq(a.swapperImd, b.swapperImd);
        assertEq(a.swapperRnnn, b.swapperRnnn);
        assertEq(b.pending, 0);
    }

    /// @dev If IMD ever blocked the hook's own address, the refund round trip (take to the hook, pay back)
    /// could not run: short fills fail, while full fills, whose fee goes straight from the manager to the
    /// recipient, still trade. The README states this; here it is pinned.
    function test_imdBlockingTheHookStopsShortFillsButNotFullFills() public {
        seedBothSides();
        imd.setBlocked(address(hook), true);
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        buy(-int256(1_000 ether));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, FEE_ON_1000_IN, "a full fill still pays the recipient");

        SwapParams memory params = limitedParams(manager, key, imdIsCurrency0, -int256(100_000 ether), 1);
        vm.prank(swapper);
        vm.expectRevert();
        actualRouter.swap(key, params, 100_000 ether);
    }

    function sawRefund(uint256 expected) internal view returns (bool seen) {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == RNNNImdFeeHook.FeeRefunded.selector) {
                assertEq(abi.decode(logs[i].data, (uint256)), expected, "refund amount");
                seen = true;
            }
        }
    }

    function test_zeroAmountSwapIsRejectedByTheManagerNotTheHook() public {
        seedBothSides();
        SwapParams memory params = SwapParams(imdIsCurrency0, 0, priceLimit(imdIsCurrency0));
        vm.prank(swapper);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    // ------------------------------------------------------------------ the launch pool: deferral on the afterSwap path too

    function test_exactOutputBuyOnTheFreshPoolDefersItsFeeAndStillDeliversTheRnnn() public {
        seedRnnnOnly();
        BalanceDelta d = buy(int256(1_000 ether));
        assertEq(rnnnDelta(d), int256(1_000 ether), "the swapper got the RNNN");
        uint256 paid = uint256(-imdDelta(d));
        uint256 pending = hook.pendingFees();
        assertGt(pending, 0, "the fee is held as a claim");
        assertEq(pending, (paid - pending) / 100, "the claim is 1% of the IMD the pool quoted");
        assertEq(imd.balanceOf(FEE_RECIPIENT), 0, "nothing delivered: the manager held no IMD");
        assertGe(imd.balanceOf(address(manager)), pending, "the claim is backed once the swapper settled");
    }

    function test_collectPendingDeliversGiftedClaimsToTheRecipientToo() public {
        seedRnnnOnly();
        buy(-int256(1_000 ether));
        // Gift the hook a claim on top of its own deferred fee.
        vm.startPrank(stranger);
        claimsRouter.deposit(Currency.wrap(address(imd)), stranger, 5_000 ether);
        manager.transfer(address(hook), uint256(uint160(address(imd))), 5_000 ether);
        vm.stopPrank();
        // The deposit moved 5,000 IMD into the manager, so the manager now holds 6,000 and owes 5,000 + fee.
        assertEq(hook.pendingFees(), 5_000 ether + FEE_ON_1000_IN);
        uint256 paid = hook.collectPending();
        assertEq(paid, 5_000 ether + FEE_ON_1000_IN);
        assertEq(
            imd.balanceOf(FEE_RECIPIENT), 5_000 ether + FEE_ON_1000_IN, "the gifted claim went to the recipient too"
        );
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(stranger), 1_000_000 ether - 5_000 ether, "the gifter got nothing back");
    }

    /// @dev A claim is only ever minted against IMD the manager really received (the swapper's input, or a
    /// deposit), and the pool's own accounting never pays out IMD it does not own, so the manager can always
    /// honour every pending claim: `collectPending` is never partial. Drain the pool through a large sell
    /// with the recipient blocked, so nothing is delivered on the way, then check the books still cover.
    function test_collectPendingIsNeverPartialBecauseClaimsAreAlwaysBacked() public {
        seedBothSides();
        imd.setBlocked(FEE_RECIPIENT, true);
        buy(-int256(1_000 ether));
        sell(-int256(5_000_000 ether));
        sell(-int256(5_000_000 ether));
        uint256 pending = hook.pendingFees();
        assertGt(pending, FEE_ON_1000_IN, "both fees were deferred");
        assertGe(imd.balanceOf(address(manager)), pending, "still fully backed after the drain");
        imd.setBlocked(FEE_RECIPIENT, false);
        uint256 paid = hook.collectPending();
        assertEq(paid, pending, "fully backed, fully paid");
        assertEq(hook.collectPending(), 0, "nothing left");
    }

    // ------------------------------------------------------------------ nobody but the recipient can reach the claims

    function test_strangerCannotBurnOrMoveTheHooksClaims() public {
        seedRnnnOnly();
        buy(-int256(1_000 ether));
        uint256 id = uint256(uint160(address(imd)));
        assertEq(hook.pendingFees(), FEE_ON_1000_IN);

        vm.startPrank(stranger);
        vm.expectRevert();
        manager.transferFrom(address(hook), stranger, id, FEE_ON_1000_IN);
        vm.expectRevert();
        claimsRouter.withdraw(Currency.wrap(address(imd)), address(hook), FEE_ON_1000_IN);
        vm.stopPrank();

        assertEq(hook.pendingFees(), FEE_ON_1000_IN, "the claim is intact");
        assertEq(imd.balanceOf(stranger), 1_000_000 ether, "the stranger gained nothing");
    }

    function test_hookNeverGrantsAnOperatorOrAllowanceOnItsClaims() public view {
        uint256 id = uint256(uint160(address(imd)));
        assertFalse(manager.isOperator(address(hook), stranger));
        assertFalse(manager.isOperator(address(hook), FEE_RECIPIENT));
        assertEq(manager.allowance(address(hook), stranger, id), 0);
        assertEq(manager.allowance(address(hook), address(swapRouter), id), 0);
    }

    // ------------------------------------------------------------------ the callbacks, called directly

    function test_senderArgumentCarriesNoAuthority() public {
        // The manager is the only caller that matters; the `sender` argument is never consulted.
        SwapParams memory params = SwapParams(imdIsCurrency0, -int256(1_000 ether), priceLimit(imdIsCurrency0));
        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta delta, uint24 lpFeeOverride) = hook.beforeSwap(stranger, key, params, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(
            BeforeSwapDeltaLibrary.getSpecifiedDelta(delta),
            int128(int256(FEE_ON_1000_IN)),
            "the full-fill fee, 1/101 of the input, declared on the IMD side"
        );
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0, "never touches the RNNN side");
        assertEq(lpFeeOverride, 0, "never overrides the LP fee");

        // A stranger pretending to be the manager through the `sender` argument gets nowhere.
        vm.prank(stranger);
        vm.expectRevert(RNNNImdFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(manager), key, params, "");
    }

    function test_beforeSwapDeclaresNothingWhenRnnnIsTheSpecifiedCurrency() public {
        // Exact-input sell (RNNN in) and exact-output buy (RNNN out): the fee waits for afterSwap.
        vm.startPrank(address(manager));
        (, BeforeSwapDelta d1,) = hook.beforeSwap(
            stranger, key, SwapParams(!imdIsCurrency0, -int256(1_000 ether), priceLimit(!imdIsCurrency0)), ""
        );
        (, BeforeSwapDelta d2,) = hook.beforeSwap(
            stranger, key, SwapParams(imdIsCurrency0, int256(1_000 ether), priceLimit(imdIsCurrency0)), ""
        );
        vm.stopPrank();
        assertEq(BeforeSwapDelta.unwrap(d1), 0);
        assertEq(BeforeSwapDelta.unwrap(d2), 0);
    }

    function test_beforeSwapDeltaCanNeverExceedTheSwapAmount() public {
        // The NoOp attack needs a delta equal to the whole amount; this hook's is at most 1/99 of it.
        for (int256 amount = -1; amount >= -1e30; amount *= 1_000) {
            SwapParams memory params = SwapParams(imdIsCurrency0, amount, priceLimit(imdIsCurrency0));
            vm.prank(address(manager));
            (, BeforeSwapDelta delta,) = hook.beforeSwap(stranger, key, params, "");
            int128 declared = BeforeSwapDeltaLibrary.getSpecifiedDelta(delta);
            assertEq(int256(declared), (-amount) / 101, "exact input: 1/101");
            assertLt(int256(declared), -amount);

            params = SwapParams(!imdIsCurrency0, -amount, priceLimit(!imdIsCurrency0));
            vm.prank(address(manager));
            (, delta,) = hook.beforeSwap(stranger, key, params, "");
            declared = BeforeSwapDeltaLibrary.getSpecifiedDelta(delta);
            assertEq(int256(declared), (-amount) / 99, "exact output: 1/99");
            assertLt(int256(declared), -amount);
        }
    }

    /// @dev An order beyond what a delta can carry declares the largest delta there is instead of failing
    /// a cast; the pool then caps the trade itself and the hook trues the fee up to the fill.
    function test_beforeSwapClampsAnOversizedDeclarationInsteadOfReverting() public {
        int256[2] memory huge = [-(int256(type(int128).max) * 101 + 101), type(int256).max / 2];
        for (uint256 i = 0; i < 2; i++) {
            bool zeroForOne = huge[i] < 0 ? imdIsCurrency0 : !imdIsCurrency0;
            SwapParams memory params = SwapParams(zeroForOne, huge[i], priceLimit(zeroForOne));
            vm.prank(address(manager));
            (, BeforeSwapDelta delta,) = hook.beforeSwap(stranger, key, params, "");
            assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), type(int128).max, "clamped to the delta range");
            assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0);
        }
    }

    function test_afterSwapOutsideASwapCannotMoveFunds() public {
        // Even the manager's address cannot make afterSwap pay anyone outside an unlock: `take`/`mint`
        // require the manager to be unlocked, so the call reverts and nothing moves.
        seedBothSides();
        SwapParams memory params = SwapParams(!imdIsCurrency0, -int256(1_000 ether), priceLimit(!imdIsCurrency0));
        BalanceDelta fake =
            imdIsCurrency0 ? toBalanceDelta(int128(1_000 ether), -1) : toBalanceDelta(-1, int128(1_000 ether));
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(address(manager));
        vm.expectRevert();
        hook.afterSwap(stranger, key, params, fake, "");
        assertEq(imd.balanceOf(FEE_RECIPIENT), before);
    }

    // ------------------------------------------------------------------ recipient shapes

    function test_aRecipientThatRejectsEthStillReceivesTheImdFee() public {
        RejectsEth contractRecipient = new RejectsEth();
        RNNNImdFeeHook hook2 = deployHook(manager, address(imd), address(contractRecipient));
        PoolKey memory key2 = poolKeyFor(address(rnnn), address(imd), IHooks(address(hook2)));
        vm.prank(FACTORY);
        manager.initialize(key2, SQRT_PRICE_1_1);
        addFullRange(lpRouter, key2, address(this), int256(100_000 ether));

        swapAs(swapRouter, key2, swapper, imdIsCurrency0, -int256(1_000 ether));
        assertEq(imd.balanceOf(address(contractRecipient)), FEE_ON_1000_IN, "paid in IMD, no ETH involved");
        assertEq(hook2.pendingFees(), 0);
    }
}

contract RNNNImdFeeHookImdIsCurrency0Test is RNNNImdFeeHookOrderingBehaviour {
    function imdBelowRnnn() internal pure override returns (bool) {
        return true;
    }
}

contract RNNNImdFeeHookImdIsCurrency1Test is RNNNImdFeeHookOrderingBehaviour {
    function imdBelowRnnn() internal pure override returns (bool) {
        return false;
    }
}

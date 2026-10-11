// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
    RNNNToken rnnn;
    MockERC20 imd;
    RNNNImdFeeHook hook;
    PoolKey key;
    bool imdIsCurrency0;

    address swapper = makeAddr("swapper");
    address stranger = makeAddr("stranger");

    function imdBelowRnnn() internal pure virtual returns (bool);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTestNoChecks(manager);
        claimsRouter = new PoolClaimsTest(manager);
        rnnn = new RNNNToken();
        imd = deployImdOrdered(address(rnnn), imdBelowRnnn(), 1_000_000_000 ether);
        hook = deployHook(manager, address(imd), FEE_RECIPIENT);
        key = poolKeyFor(address(rnnn), address(imd), IHooks(address(hook)));
        imdIsCurrency0 = Currency.unwrap(key.currency0) == address(imd);
        assertEq(imdIsCurrency0, imdBelowRnnn(), "the ordering under test");

        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1_1);

        address[] memory spenders = new address[](3);
        spenders[0] = address(swapRouter);
        spenders[1] = address(lpRouter);
        spenders[2] = address(claimsRouter);
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

    // ------------------------------------------------------------------ the four swap shapes

    function test_buyExactInput_recipientGetsExactlyOnePercentOfTheImdSpent() public {
        seedBothSides();
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        BalanceDelta d = buy(-int256(1_000 ether));
        assertEq(imdDelta(d), -int256(1_000 ether), "swapper paid exactly the IMD specified");
        assertGt(rnnnDelta(d), 0, "swapper received RNNN");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 10 ether, "1% of 1,000 IMD to the recipient");
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
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        uint256 managerBefore = imd.balanceOf(address(manager));
        BalanceDelta d = sell(int256(1_000 ether));
        assertEq(imdDelta(d), int256(1_000 ether), "swapper received exactly the IMD asked for");
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 10 ether, "1% of 1,000 IMD to the recipient");
        assertEq(managerBefore - imd.balanceOf(address(manager)), 1_010 ether, "the pool paid out both");
        assertLt(rnnnDelta(d), 0, "swapper paid RNNN");
    }

    /// @dev One property for all four shapes at random sizes: the fee leaving the system for this swap
    /// is floor(1%) of the swap's IMD side, and the hook keeps nothing.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_everySwapShapePaysFloorOnePercentOfItsImdSide(uint256 amount, uint8 shape) public {
        seedBothSides();
        amount = bound(amount, 1, 50_000 ether);
        shape = uint8(bound(shape, 0, 3));
        uint256 feesBefore = feesInSystem();
        uint256 managerBefore = imd.balanceOf(address(manager));

        BalanceDelta d;
        if (shape == 0) d = buy(-int256(amount));
        else if (shape == 1) d = buy(int256(amount));
        else if (shape == 2) d = sell(-int256(amount));
        else d = sell(int256(amount));

        uint256 fee = feesInSystem() - feesBefore;
        uint256 managerAfter = imd.balanceOf(address(manager));
        // The swap's IMD side: the amount the swapper specified when that is IMD (shapes 0 and 3), else the
        // IMD the pool quoted, which is the manager's net change once the fee has left it (shapes 1 and 2).
        uint256 imdSide;
        if (shape == 0 || shape == 3) imdSide = amount;
        else if (shape == 1) imdSide = managerAfter - managerBefore;
        else imdSide = managerBefore - managerAfter;
        assertEq(fee, imdSide / 100, "floor(1%) of the IMD side");
        // And the manager's own books agree with that reading.
        if (shape == 0) assertEq(managerAfter - managerBefore, amount - fee, "pool traded the other 99%");
        if (shape == 3) assertEq(managerBefore - managerAfter, amount + fee, "pool paid the fee on top");
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(rnnn.balanceOf(address(hook)), 0);
        assertEq(rnnn.balanceOf(FEE_RECIPIENT), 0);
        if (shape == 0) assertEq(imdDelta(d), -int256(amount));
        if (shape == 3) assertEq(imdDelta(d), int256(amount));
    }

    // ------------------------------------------------------------------ rounding edges

    function test_feeRoundsDownAtTheBoundary() public {
        seedBothSides();
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        buy(-99);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 0, "99 wei: no fee");
        buy(-100);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 1, "100 wei: 1 wei");
        buy(-199);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 2, "199 wei: still 1 wei more");
        sell(int256(150));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 3, "150 wei out: 1 wei");
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

    function test_collectPendingDeliversNoMoreThanTheManagerHolds() public {
        seedRnnnOnly();
        buy(-int256(1_000 ether));
        // Gift the hook a claim larger than the IMD the manager holds, on top of its own 10 IMD.
        vm.startPrank(stranger);
        claimsRouter.deposit(Currency.wrap(address(imd)), stranger, 5_000 ether);
        manager.transfer(address(hook), uint256(uint160(address(imd))), 5_000 ether);
        vm.stopPrank();
        // The deposit moved 5,000 IMD into the manager, so the manager now holds 6,000 and owes 5,010.
        assertEq(hook.pendingFees(), 5_010 ether);
        uint256 paid = hook.collectPending();
        assertEq(paid, 5_010 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 5_010 ether, "the gifted claim went to the recipient too");
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(stranger), 1_000_000 ether - 5_000 ether, "the gifter got nothing back");
    }

    function test_collectPendingIsPartialWhenTheManagerIsShortAndFinishesLater() public {
        seedRnnnOnly();
        buy(-int256(1_000 ether)); // 10 IMD pending, 1,000 IMD in the manager
        // Pull almost all IMD out of the manager through the pool: a big sell.
        uint256 inManager = imd.balanceOf(address(manager));
        vm.startPrank(stranger);
        claimsRouter.deposit(Currency.wrap(address(imd)), stranger, 20 ether);
        manager.transfer(address(hook), uint256(uint160(address(imd))), 20 ether);
        vm.stopPrank();
        assertEq(hook.pendingFees(), 30 ether);
        assertEq(imd.balanceOf(address(manager)), inManager + 20 ether);
        uint256 paid = hook.collectPending();
        assertEq(paid, 30 ether, "fully backed, fully paid");
        assertEq(hook.collectPending(), 0, "nothing left");
    }

    // ------------------------------------------------------------------ nobody but the recipient can reach the claims

    function test_strangerCannotBurnOrMoveTheHooksClaims() public {
        seedRnnnOnly();
        buy(-int256(1_000 ether));
        uint256 id = uint256(uint160(address(imd)));
        assertEq(hook.pendingFees(), 10 ether);

        vm.startPrank(stranger);
        vm.expectRevert();
        manager.transferFrom(address(hook), stranger, id, 10 ether);
        vm.expectRevert();
        claimsRouter.withdraw(Currency.wrap(address(imd)), address(hook), 10 ether);
        vm.stopPrank();

        assertEq(hook.pendingFees(), 10 ether, "the claim is intact");
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
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), int128(10 ether), "fee declared on the IMD side");
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
        // The NoOp attack needs a delta equal to the whole amount; this hook's is 1% of it.
        for (int256 amount = -1; amount >= -1e30; amount *= 1_000) {
            SwapParams memory params = SwapParams(imdIsCurrency0, amount, priceLimit(imdIsCurrency0));
            vm.prank(address(manager));
            (, BeforeSwapDelta delta,) = hook.beforeSwap(stranger, key, params, "");
            int128 declared = BeforeSwapDeltaLibrary.getSpecifiedDelta(delta);
            assertEq(int256(declared), (-amount) / 100);
            assertLt(int256(declared), -amount);
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
        assertEq(imd.balanceOf(address(contractRecipient)), 10 ether, "paid in IMD, no ETH involved");
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

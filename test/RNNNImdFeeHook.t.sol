// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookFlags} from "../src/HookFlags.sol";
import {RNNNImdFeeHook} from "../src/RNNNImdFeeHook.sol";
import {RNNNToken} from "../src/RNNNToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ActualDeltaRouter} from "./mocks/ActualDeltaRouter.sol";

/// @notice Shared scaffolding: a PoolManager, the launch token, a mock IMD, the hook mined to its
/// flags, the launch pool (LP fee 12500, tick spacing 60, price 1:1) and v4-core's test routers.
abstract contract RNNNImdFeeHookTestBase is Test {
    using StateLibrary for IPoolManager;

    /// @dev The fixed recipient the brief names. Tests use the real value so the assertions read as
    /// the brief does.
    address constant FEE_RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;
    /// @dev Stands in for the IMD launch factory, which deploys the hook and initializes the pool.
    address constant FACTORY = address(0xFAC7);
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant LP_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    int24 constant MIN_TICK = -887_220;
    int24 constant MAX_TICK = 887_220;

    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    RNNNToken rnnn;
    MockERC20 imd;
    RNNNImdFeeHook hook;
    PoolKey key;
    bool imdIsCurrency0;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        rnnn = new RNNNToken();
        imd = new MockERC20("IMD", "IMD", 1_000_000_000 ether);

        hook = deployHook(manager, address(imd), FEE_RECIPIENT);
        key = poolKeyFor(address(rnnn), address(imd), hook);
        imdIsCurrency0 = Currency.unwrap(key.currency0) == address(imd);

        rnnn.approve(address(swapRouter), type(uint256).max);
        rnnn.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
    }

    /// @dev Mines a CREATE2 salt until the hook lands on an address carrying exactly `FLAGS`, as the
    /// launch deployer does, then deploys it there.
    function deployHook(PoolManager manager_, address imd_, address recipient) internal returns (RNNNImdFeeHook) {
        bytes memory creationCode =
            abi.encodePacked(type(RNNNImdFeeHook).creationCode, abi.encode(address(manager_), imd_, recipient));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            bytes32 salt = bytes32(i);
            address at;
            assembly ("memory-safe") {
                at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            require(at == predicted, "hook landed elsewhere");
            return RNNNImdFeeHook(at);
        }
        revert("no salt matched the flags");
    }

    function poolKeyFor(address a, address b, IHooks hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    function initializeFromFactory() internal {
        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function addFullRangeLiquidity(uint128 liquidity) internal {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(uint256(liquidity)), 0), "");
    }

    /// @dev Seeds only RNNN: a range entirely on the RNNN side of the current 1:1 price, the way the
    /// launch opens its pool.
    function addRnnnOnlyLiquidity(uint128 liquidity) internal {
        (int24 lower, int24 upper) = imdIsCurrency0 ? (MIN_TICK, -TICK_SPACING) : (TICK_SPACING, MAX_TICK);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), "");
    }

    /// @dev Spend `amountSpecified` of IMD (negative) or receive that many RNNN (positive).
    function buy(int256 amountSpecified) internal returns (BalanceDelta) {
        return swapDir(imdIsCurrency0, amountSpecified);
    }

    /// @dev Spend `amountSpecified` of RNNN (negative) or receive that many IMD (positive).
    function sell(int256 amountSpecified) internal returns (BalanceDelta) {
        return swapDir(!imdIsCurrency0, amountSpecified);
    }

    function swapDir(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        return swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    /// @dev Swap parameters whose price limit sits one tick spacing from the pool's current price, so
    /// the pool stops filling there: the slippage-protected shape of a swap, and the shape a
    /// front-runner forces when they push the price to a victim's limit.
    function limitedParams(bool zeroForOne, int256 amountSpecified) internal view returns (SwapParams memory) {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(zeroForOne ? tick - TICK_SPACING : tick + TICK_SPACING)
        });
    }

    /// @dev How a revert inside `afterSwap` reaches the caller of `PoolManager.unlock`: wrapped by
    /// v4-core with the hook address, the callback selector and `HookCallFailed`.
    function wrappedAfterSwapRevert(bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    struct Balances {
        uint256 swapperImd;
        uint256 swapperRnnn;
        uint256 recipientImd;
        uint256 recipientRnnn;
        uint256 managerImd;
        uint256 managerRnnn;
        uint256 hookImd;
        uint256 hookRnnn;
    }

    function snapshot() internal view returns (Balances memory b) {
        b.swapperImd = imd.balanceOf(address(this));
        b.swapperRnnn = rnnn.balanceOf(address(this));
        b.recipientImd = imd.balanceOf(FEE_RECIPIENT);
        b.recipientRnnn = rnnn.balanceOf(FEE_RECIPIENT);
        b.managerImd = imd.balanceOf(address(manager));
        b.managerRnnn = rnnn.balanceOf(address(manager));
        b.hookImd = imd.balanceOf(address(hook));
        b.hookRnnn = rnnn.balanceOf(address(hook));
    }
}

/// @notice The hook on a funded pool: both sides of liquidity, so every fee is delivered at once.
contract RNNNImdFeeHookTest is RNNNImdFeeHookTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        initializeFromFactory();
        addFullRangeLiquidity(1_000_000 ether);
    }

    // ------------------------------------------------------------------ configuration

    function test_constructorPinsConfiguration() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.feeRecipient(), FEE_RECIPIENT);
        assertEq(hook.FEE_BPS(), 100);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(RNNNImdFeeHook.ZeroAddress.selector);
        new RNNNImdFeeHook(IPoolManager(address(0)), address(imd), FEE_RECIPIENT);
        vm.expectRevert(RNNNImdFeeHook.ZeroAddress.selector);
        new RNNNImdFeeHook(manager, address(0), FEE_RECIPIENT);
        vm.expectRevert(RNNNImdFeeHook.ZeroAddress.selector);
        new RNNNImdFeeHook(manager, address(imd), address(0));
    }

    function test_constructorRejectsAnAddressWithoutTheFlags() public {
        // A plain CREATE deploy lands on an address that does not carry the permission bits.
        vm.expectRevert();
        new RNNNImdFeeHook(manager, address(imd), FEE_RECIPIENT);
    }

    function test_permissionsMatchTheMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), LP_FEE));
    }

    // ------------------------------------------------------------------ buys

    function test_buyExactInput_sendsOnePercentOfImdInToRecipient() public {
        Balances memory before = snapshot();
        uint256 amountIn = 1_000 ether;
        // The swapper's 1,000 IMD is the pool's leg plus 1% of it: the pool trades 1000 * 100/101 and
        // the fee is 1000 / 101 IMD, which is exactly 1% (floor) of the pool's IMD side.
        uint256 expectedFee = amountIn / 101;

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(expectedFee);
        buy(-int256(amountIn));

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 pooled = after_.managerImd - before.managerImd;
        assertEq(fee, expectedFee, "recipient gets 1/101 of the swapper's IMD");
        assertEq(fee, pooled / 100, "which is exactly 1% of the IMD side the pool traded");
        assertEq(before.swapperImd - after_.swapperImd, amountIn, "swapper pays exactly what they specified");
        assertEq(pooled, amountIn - fee, "the pool trades the rest");
        assertGt(after_.swapperRnnn, before.swapperRnnn, "swapper received RNNN");
        assertEq(after_.recipientRnnn, before.recipientRnnn, "no RNNN leaves for the recipient");
        assertEq(after_.hookImd, 0, "the hook keeps nothing");
        assertEq(after_.hookRnnn, 0, "the hook keeps nothing");
        assertEq(hook.pendingFees(), 0, "nothing deferred when the pool holds IMD");
    }

    function test_buyExactOutput_chargesOnePercentOfImdOnTop() public {
        Balances memory before = snapshot();
        uint256 wantRnnn = 500 ether;

        buy(int256(wantRnnn));

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 paid = before.swapperImd - after_.swapperImd;
        uint256 pooled = after_.managerImd - before.managerImd;
        assertEq(after_.swapperRnnn - before.swapperRnnn, wantRnnn, "swapper gets exactly the RNNN asked for");
        assertEq(paid, pooled + fee, "swapper pays the pool's quote plus the fee");
        assertEq(fee, pooled / 100, "fee is exactly 1% of the IMD the pool quoted");
        assertGt(fee, 0);
        assertEq(hook.pendingFees(), 0);
    }

    // ------------------------------------------------------------------ sells

    function test_sellExactInput_sendsOnePercentOfImdOutToRecipient() public {
        Balances memory before = snapshot();
        uint256 rnnnIn = 1_000 ether;

        sell(-int256(rnnnIn));

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 received = after_.swapperImd - before.swapperImd;
        uint256 pooledOut = before.managerImd - after_.managerImd;
        assertEq(before.swapperRnnn - after_.swapperRnnn, rnnnIn, "swapper spends exactly the RNNN specified");
        assertEq(pooledOut, received + fee, "the pool's IMD output splits into swapper output and fee");
        assertEq(fee, pooledOut / 100, "fee is exactly 1% of the IMD side");
        assertGt(fee, 0);
        assertEq(after_.recipientRnnn, before.recipientRnnn, "recipient receives IMD, never RNNN");
        assertEq(hook.pendingFees(), 0);
    }

    function test_sellExactOutput_swapperGetsExactlyWhatTheyAskedAndRecipientOnePercent() public {
        Balances memory before = snapshot();
        uint256 wantImd = 1_000 ether;
        // The swapper's 1,000 IMD is the pool's leg minus 1% of it: the pool pays out 1000 * 100/99
        // and the fee is 1000 / 99 IMD, exactly 1% (floor) of the pool's IMD side.
        uint256 expectedFee = wantImd / 99;

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(expectedFee);
        sell(int256(wantImd));

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 pooledOut = before.managerImd - after_.managerImd;
        assertEq(after_.swapperImd - before.swapperImd, wantImd, "swapper receives exactly the IMD asked for");
        assertEq(fee, expectedFee, "recipient gets 1/99 of the swapper's IMD");
        assertEq(fee, pooledOut / 100, "which is exactly 1% of the IMD side the pool paid out");
        assertEq(pooledOut, wantImd + fee, "the pool pays out both");
        assertGt(before.swapperRnnn - after_.swapperRnnn, 0, "swapper paid RNNN");
    }

    /// @dev One base on every shape: the fee is 1% (floor) of the pool's IMD leg whether the swapper
    /// specified IMD or RNNN, input or output. Finding 80701ca0 measured 1.0101%, 0.9901% and 1% here.
    function test_feeBaseIsThePoolsImdSideOnEveryShape() public {
        int256[4] memory amounts = [int256(-1_000 ether), int256(500 ether), int256(-1_000 ether), int256(1_000 ether)];
        for (uint256 i = 0; i < 4; i++) {
            Balances memory before = snapshot();
            if (i < 2) buy(amounts[i]);
            else sell(amounts[i]);
            Balances memory after_ = snapshot();
            uint256 fee = after_.recipientImd - before.recipientImd;
            uint256 poolLeg = i < 2 ? after_.managerImd - before.managerImd : before.managerImd - after_.managerImd;
            assertGt(fee, 0);
            assertEq(fee, poolLeg / 100, "fee is 1% of the pool's IMD leg");
        }
    }

    // ------------------------------------------------------------------ properties

    function testFuzz_buyExactInput_feeIsAlwaysOnePercentFloor(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 100_000 ether);
        Balances memory before = snapshot();

        buy(-int256(amountIn));

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 pooled = after_.managerImd - before.managerImd;
        assertEq(fee, amountIn / 101, "fee is the full-fill declaration, 1/101 of the input");
        // floor(X/101) and floor((X - floor(X/101))/100) differ by one wei when X mod 101 == 100.
        assertApproxEqAbs(fee, pooled / 100, 1, "and 1% (floor) of the pool's IMD side, to a wei");
        assertLe(fee, pooled / 100, "never more than 1% of the pool's side");
        assertEq(before.swapperImd - after_.swapperImd, amountIn, "swapper pays exactly amountIn");
        assertEq(pooled, amountIn - fee, "IMD is conserved");
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function testFuzz_sellExactInput_imdIsConserved(uint256 rnnnIn) public {
        rnnnIn = bound(rnnnIn, 1, 100_000 ether);
        Balances memory before = snapshot();

        sell(-int256(rnnnIn));

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 received = after_.swapperImd - before.swapperImd;
        uint256 pooledOut = before.managerImd - after_.managerImd;
        assertEq(pooledOut, received + fee, "IMD is conserved");
        assertEq(fee, pooledOut / 100, "fee is floor(1%) of the IMD side");
    }

    function test_tinySwapBelowOneHundredWeiPaysNoFeeAndStillTrades() public {
        Balances memory before = snapshot();
        buy(-50);
        Balances memory after_ = snapshot();
        assertEq(after_.recipientImd, before.recipientImd, "no fee below 100 wei");
        assertEq(before.swapperImd - after_.swapperImd, 50);
    }

    function test_hookDataIsIgnored() public {
        Balances memory before = snapshot();
        SwapParams memory params = SwapParams({
            zeroForOne: imdIsCurrency0,
            amountSpecified: -1_000 ether,
            sqrtPriceLimitX96: imdIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(address(0xBAD), uint256(1)));
        Balances memory after_ = snapshot();
        assertEq(after_.recipientImd - before.recipientImd, uint256(1_000 ether) / 101);
    }

    function test_feeKeepsFlowingAcrossManySwaps() public {
        uint256 start = imd.balanceOf(FEE_RECIPIENT);
        for (uint256 i = 0; i < 5; i++) {
            buy(-100 ether);
            sell(int256(100 ether));
        }
        uint256 perRound = uint256(100 ether) / 101 + uint256(100 ether) / 99;
        assertEq(imd.balanceOf(FEE_RECIPIENT) - start, 5 * perRound, "ten swaps, each 1% of its pool leg");
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_liquidityCanBeAddedAndRemovedWithoutAnyFee() public {
        Balances memory before = snapshot();
        addFullRangeLiquidity(1_000 ether);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, -int256(1_000 ether), 0), "");
        Balances memory after_ = snapshot();
        assertEq(after_.recipientImd, before.recipientImd, "liquidity operations pay no fee");
        // Rounding on mint/burn can cost the LP a wei or two; nothing goes to the hook or recipient.
        assertLe(before.swapperImd - after_.swapperImd, 2);
        assertLe(before.swapperRnnn - after_.swapperRnnn, 2);
    }

    function test_collectPendingWithNothingPendingIsANoOp() public {
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(address(0xA11CE));
        uint256 paid = hook.collectPending();
        assertEq(paid, 0);
        assertEq(imd.balanceOf(FEE_RECIPIENT), before);
    }

    // ------------------------------------------------------------------ access control

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.expectRevert(RNNNImdFeeHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(RNNNImdFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(RNNNImdFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, zero, "");
        vm.expectRevert(RNNNImdFeeHook.NotPoolManager.selector);
        hook.unlockCallback("");

        // Callbacks the hook does not declare are not callable by anyone, the manager included.
        vm.startPrank(address(manager));
        vm.expectRevert(RNNNImdFeeHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(RNNNImdFeeHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, 1 ether, 0), "");
        vm.expectRevert(RNNNImdFeeHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, -1 ether, 0), "");
        vm.expectRevert(RNNNImdFeeHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, 1 ether, 0), zero, zero, "");
        vm.expectRevert(RNNNImdFeeHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, -1 ether, 0), zero, zero, "");
        vm.expectRevert(RNNNImdFeeHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(RNNNImdFeeHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    /// @dev The hook has no owner and no privileged entry point: every administrative selector a
    /// hook of this kind might carry is absent, from any caller, and the configuration is immutable.
    function test_hasNoPrivilegedFunctions() public {
        string[14] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "setFeeRecipient(address)",
            "setRecipient(address)",
            "setFee(uint256)",
            "setFeeBps(uint256)",
            "pause()",
            "unpause()",
            "mint(address,uint256)",
            "withdraw(address,uint256)",
            "sweep(address)",
            "rescueTokens(address,address,uint256)",
            "upgradeTo(address)"
        ];
        address[3] memory callers = [address(this), FACTORY, address(0xBEEF)];
        for (uint256 c = 0; c < callers.length; c++) {
            for (uint256 i = 0; i < signatures.length; i++) {
                bytes memory data = abi.encodeWithSignature(signatures[i], address(0xBEEF), uint256(1), uint256(1));
                vm.prank(callers[c]);
                (bool ok,) = address(hook).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(hook.feeRecipient(), FEE_RECIPIENT, "recipient cannot change");
        assertEq(hook.FEE_BPS(), 100, "fee cannot change");
        // No ETH entry point either.
        (bool sent,) = address(hook).call{value: 1 ether}("");
        assertFalse(sent, "the hook does not accept ETH");
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "over the EIP-170 limit");
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
        }
    }
}

/// @notice Pool initialization: who may open a pool on the hook, and which pools.
contract RNNNImdFeeHookInitializeTest is RNNNImdFeeHookTestBase {
    using StateLibrary for IPoolManager;

    function test_factoryInitializesTheLaunchPool() public {
        initializeFromFactory();
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    function test_anyoneMayInitializeAnImdPoolAtAnyListedFeeOrSpacing() public {
        // The hook does not gate the initializer, the LP fee or the spacing: the launch policy does.
        key.fee = 3_000;
        key.tickSpacing = 10;
        vm.prank(address(0xA11CE));
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_rejectsAPoolWithoutAnImdSide() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1 ether);
        PoolKey memory bad = poolKeyFor(address(rnnn), address(other), hook);
        vm.prank(FACTORY);
        vm.expectRevert();
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    function test_rejectsBeforeInitializeFromANonManager() public {
        vm.prank(FACTORY);
        vm.expectRevert(RNNNImdFeeHook.NotPoolManager.selector);
        hook.beforeInitialize(FACTORY, key, SQRT_PRICE_1_1);
    }
}

/// @notice The launch case: a fresh PoolManager whose pool is seeded with RNNN only, so it holds no
/// IMD when the first buy's fee comes due. The fee is held as a claim and delivered later; the swap
/// itself never fails.
contract RNNNImdFeeHookFreshPoolTest is RNNNImdFeeHookTestBase {
    function setUp() public override {
        super.setUp();
        initializeFromFactory();
        addRnnnOnlyLiquidity(1_000_000 ether);
        assertEq(imd.balanceOf(address(manager)), 0, "the manager starts with no IMD");
    }

    /// @dev The fee on a full-fill exact-input buy of 1,000 IMD: 1/101 of it, 1% of the pool's leg.
    uint256 constant FEE_ON_1000_IN = uint256(1_000 ether) / 101;

    function test_firstBuyDefersTheFeeAsAClaimInsteadOfReverting() public {
        Balances memory before = snapshot();

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeeDeferred(FEE_ON_1000_IN);
        buy(-1_000 ether);

        Balances memory after_ = snapshot();
        assertEq(before.swapperImd - after_.swapperImd, 1_000 ether, "the swap went through at the full amount");
        assertGt(after_.swapperRnnn, before.swapperRnnn, "the swapper received RNNN");
        assertEq(after_.recipientImd, before.recipientImd, "nothing delivered yet: the manager held no IMD");
        assertEq(hook.pendingFees(), FEE_ON_1000_IN, "the fee is held as an ERC-6909 claim");
        assertEq(after_.managerImd, 1_000 ether, "the swapper's IMD is now in the manager");
        assertEq(FEE_ON_1000_IN, (1_000 ether - FEE_ON_1000_IN) / 100, "1% of the pool's IMD leg");
    }

    function test_anyoneCanCollectThePendingFeeForTheRecipient() public {
        buy(-1_000 ether);
        assertEq(hook.pendingFees(), FEE_ON_1000_IN);

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(FEE_ON_1000_IN);
        vm.prank(address(0xA11CE));
        uint256 paid = hook.collectPending();

        assertEq(paid, FEE_ON_1000_IN);
        assertEq(imd.balanceOf(FEE_RECIPIENT), FEE_ON_1000_IN, "the recipient received exactly 1% in IMD");
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(manager)), 1_000 ether - FEE_ON_1000_IN);
    }

    function test_nextSwapDeliversTheDeferredFeeAlongWithItsOwn() public {
        buy(-1_000 ether);
        assertEq(hook.pendingFees(), FEE_ON_1000_IN);

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(2 * FEE_ON_1000_IN);
        buy(-1_000 ether);

        assertEq(imd.balanceOf(FEE_RECIPIENT), 2 * FEE_ON_1000_IN, "both fees delivered");
        assertEq(hook.pendingFees(), 0);
    }

    /// @dev Finding 789cc455, case B: the launch pool holds no IMD, so an exact-output sell can fill
    /// nothing. The old hook charged 1% of the IMD asked for and paid out none. Now the fill is short,
    /// the manager has no IMD to return the declared fee from, and the swap is refused: the seller's
    /// IMD is untouched and the recipient is owed nothing.
    function test_exactOutputSellThatCannotFillIsRefusedNotCharged() public {
        Balances memory before = snapshot();

        vm.expectRevert(wrappedAfterSwapRevert(RNNNImdFeeHook.ShortFillNotRefundable.selector));
        sell(int256(1_000 ether));

        Balances memory after_ = snapshot();
        assertEq(after_.swapperImd, before.swapperImd, "a seller never ends a sell with less IMD");
        assertEq(after_.swapperRnnn, before.swapperRnnn);
        assertEq(after_.recipientImd, before.recipientImd);
        assertEq(hook.pendingFees(), 0, "nothing booked for the recipient");
    }

    /// @dev Same state, exact-input buy with a price limit one spacing away: the pool fills only up
    /// to the limit, the manager holds no IMD yet, and the swap is refused rather than charged 1% of
    /// the whole order.
    function test_priceLimitedBuyBeforeAnyImdIsInTheManagerIsRefused() public {
        ActualDeltaRouter router = new ActualDeltaRouter(manager);
        imd.approve(address(router), type(uint256).max);
        Balances memory before = snapshot();
        SwapParams memory params = limitedParams(imdIsCurrency0, -100_000 ether);

        vm.expectRevert(wrappedAfterSwapRevert(RNNNImdFeeHook.ShortFillNotRefundable.selector));
        router.swap(key, params, 100_000 ether);

        Balances memory after_ = snapshot();
        assertEq(after_.swapperImd, before.swapperImd);
        assertEq(hook.pendingFees(), 0);
    }

    /// @dev Once one buy has settled, the manager holds IMD and a short fill is trued up instead.
    function test_priceLimitedBuyAfterTheFirstBuyIsTruedUpToTheFill() public {
        buy(-1_000 ether);
        ActualDeltaRouter router = new ActualDeltaRouter(manager);
        imd.approve(address(router), type(uint256).max);
        Balances memory before = snapshot();

        router.swap(key, limitedParams(imdIsCurrency0, -100_000 ether), 100_000 ether);

        Balances memory after_ = snapshot();
        uint256 paid = before.swapperImd - after_.swapperImd;
        uint256 delivered = after_.recipientImd - before.recipientImd;
        uint256 pooled = after_.managerImd - before.managerImd;
        assertLt(paid, 100_000 ether, "only the filled part was paid for");
        assertEq(hook.pendingFees(), 0, "the earlier claim rode along with this fee");
        assertEq(paid, pooled + delivered, "IMD is conserved");
        // The manager gave up the earlier claim out of its balance, so the pool's leg this swap is
        // what it gained plus that claim; this swap's own fee is what was delivered beyond the claim.
        uint256 poolLeg = pooled + FEE_ON_1000_IN;
        uint256 feeThisSwap = delivered - FEE_ON_1000_IN;
        assertEq(feeThisSwap, poolLeg / 100, "1% of the IMD that actually traded");
        assertEq(paid, poolLeg + feeThisSwap, "the swapper paid the fill plus 1%, nothing on the unfilled rest");
    }

    function test_sellOnAFreshPoolAfterABuyPaysAtOnce() public {
        buy(-1_000 ether);
        uint256 recipientBefore = imd.balanceOf(FEE_RECIPIENT);
        Balances memory before = snapshot();
        sell(-100 ether);
        Balances memory after_ = snapshot();
        uint256 fee = imd.balanceOf(FEE_RECIPIENT) - recipientBefore;
        uint256 received = after_.swapperImd - before.swapperImd;
        uint256 pooledOut = before.managerImd - after_.managerImd;
        assertGt(fee, 0);
        assertEq(pooledOut, received + fee);
        assertGe(fee, pooledOut / 100, "the pending claim rides along with this swap's 1%");
    }

    function test_recipientNeverReceivesRnnn() public {
        buy(-1_000 ether);
        buy(-1_000 ether);
        sell(-100 ether);
        hook.collectPending();
        assertEq(rnnn.balanceOf(FEE_RECIPIENT), 0);
        assertEq(rnnn.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }
}

/// @notice Short fills on a funded pool (finding 789cc455, case A): a price limit stops the pool
/// before the specified amount is used up. The fee must be 1% of what traded, and the swapper must
/// pay for nothing else. These swaps go through a router that settles the PoolManager's actual
/// deltas, as the Universal Router does, because the hook returns the unowed part of the declared
/// fee to the router inside the swap.
contract RNNNImdFeeHookShortFillTest is RNNNImdFeeHookTestBase {
    ActualDeltaRouter router;

    function setUp() public override {
        super.setUp();
        initializeFromFactory();
        addFullRangeLiquidity(1_000_000 ether);
        router = new ActualDeltaRouter(manager);
        imd.approve(address(router), type(uint256).max);
        rnnn.approve(address(router), type(uint256).max);
    }

    function test_priceLimitedExactInputBuy_paysOnePercentOfTheImdThatTraded() public {
        Balances memory before = snapshot();
        uint256 requested = 100_000 ether;

        router.swap(key, limitedParams(imdIsCurrency0, -int256(requested)), requested);

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 paid = before.swapperImd - after_.swapperImd;
        uint256 poolLeg = after_.managerImd - before.managerImd;
        assertLt(poolLeg, requested / 2, "the limit stopped the fill well short of the order");
        assertGt(fee, 0);
        assertEq(fee, poolLeg / 100, "fee is 1% of the IMD side that traded, not of the order");
        assertEq(paid, poolLeg + fee, "the swapper paid the fill plus its 1%, nothing on the rest");
        assertEq(after_.hookImd, 0, "the hook keeps nothing");
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(router)), 0, "the router returned the unused input");
    }

    function test_priceLimitedExactInputBuy_emitsTheRefund() public {
        uint256 requested = 100_000 ether;
        uint256 declared = requested / 101;
        uint256 recipientBefore = imd.balanceOf(FEE_RECIPIENT);
        vm.recordLogs();
        router.swap(key, limitedParams(imdIsCurrency0, -int256(requested)), requested);
        uint256 fee = imd.balanceOf(FEE_RECIPIENT) - recipientBefore;

        bool seen;
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == RNNNImdFeeHook.FeeRefunded.selector) {
                assertEq(abi.decode(logs[i].data, (uint256)), declared - fee, "refund is the unowed part");
                seen = true;
            }
        }
        assertTrue(seen, "FeeRefunded emitted");
    }

    function test_priceLimitedExactOutputSell_paysOnePercentOfTheImdThatTraded() public {
        Balances memory before = snapshot();
        uint256 requested = 100_000 ether;

        router.swap(key, limitedParams(!imdIsCurrency0, int256(requested)), 1_000_000 ether);

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 received = after_.swapperImd - before.swapperImd;
        uint256 poolLeg = before.managerImd - after_.managerImd;
        assertLt(received, requested / 2, "the limit stopped the fill well short of the order");
        assertGt(fee, 0);
        assertEq(fee, poolLeg / 100, "fee is 1% of the IMD side that traded");
        assertEq(received, poolLeg - fee, "the seller received the fill minus its 1%");
        assertEq(hook.pendingFees(), 0);
        assertEq(rnnn.balanceOf(address(router)), 0, "the router returned the unused RNNN");
    }

    /// @dev The same router on full fills agrees with the PoolSwapTest results: no refund happens
    /// when the fill is complete.
    function test_fullFillThroughTheActualDeltaRouterNeedsNoRefund() public {
        Balances memory before = snapshot();
        SwapParams memory params = SwapParams({
            zeroForOne: imdIsCurrency0,
            amountSpecified: -1_000 ether,
            sqrtPriceLimitX96: imdIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        router.swap(key, params, 1_000 ether);
        Balances memory after_ = snapshot();
        assertEq(before.swapperImd - after_.swapperImd, 1_000 ether);
        assertEq(after_.recipientImd - before.recipientImd, uint256(1_000 ether) / 101);
    }

    /// @dev Finding 72cf4725: an order far beyond any balance is "swap to the limit" in v4. The hook
    /// no longer fails a cast on it; it declares a fee within the delta range and the swap then
    /// follows the short-fill rule. The unowed part here exceeds all the IMD that exists, so the
    /// refund cannot be sourced and the swap is refused with the hook's own error, not an overflow.
    function test_oversizedOrderFailsWithTheShortFillErrorNotAnOverflow() public {
        int256 huge = -(100 * int256(type(int128).max) + 100);
        uint256 everything = imd.balanceOf(address(this));
        SwapParams memory params = limitedParams(imdIsCurrency0, huge);
        vm.expectRevert(wrappedAfterSwapRevert(RNNNImdFeeHook.ShortFillNotRefundable.selector));
        router.swap(key, params, everything);
    }

    /// @dev An oversized order the manager can refund goes through: 1,000 IMD trades at most to the
    /// limit, the declared fee is 1/101 of the order, and the manager holds enough IMD to return the
    /// difference.
    function test_largeOrderWithinTheManagersImdIsTruedUp() public {
        Balances memory before = snapshot();
        uint256 requested = 50_000_000 ether;
        router.swap(key, limitedParams(imdIsCurrency0, -int256(requested)), requested);
        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        uint256 poolLeg = after_.managerImd - before.managerImd;
        assertEq(fee, poolLeg / 100);
        assertEq(before.swapperImd - after_.swapperImd, poolLeg + fee);
    }
}

/// @notice Finding f766513a: IMD on Robinhood Chain carries a blocklist. If the recipient is ever
/// blocked, the fee is held as a claim rather than halting swaps, and is delivered once the transfer
/// is accepted again.
contract RNNNImdFeeHookBlockedRecipientTest is RNNNImdFeeHookTestBase {
    function setUp() public override {
        super.setUp();
        initializeFromFactory();
        addFullRangeLiquidity(1_000_000 ether);
        imd.setBlocked(FEE_RECIPIENT, true);
    }

    function test_buyStillTradesAndDefersTheFeeWhenTheRecipientIsBlocked() public {
        Balances memory before = snapshot();
        uint256 expectedFee = uint256(1_000 ether) / 101;

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeeDeferred(expectedFee);
        buy(-1_000 ether);

        Balances memory after_ = snapshot();
        assertEq(before.swapperImd - after_.swapperImd, 1_000 ether, "the trade went through");
        assertGt(after_.swapperRnnn, before.swapperRnnn);
        assertEq(after_.recipientImd, before.recipientImd, "nothing could be delivered");
        assertEq(hook.pendingFees(), expectedFee, "the fee waits as a claim");
    }

    function test_sellStillTradesAndDefersTheFeeWhenTheRecipientIsBlocked() public {
        Balances memory before = snapshot();
        sell(-1_000 ether);
        Balances memory after_ = snapshot();
        uint256 poolLeg = before.managerImd - after_.managerImd + hook.pendingFees();
        assertGt(after_.swapperImd, before.swapperImd, "the seller was paid");
        assertEq(hook.pendingFees(), poolLeg / 100, "1% waits as a claim");
        assertEq(after_.recipientImd, before.recipientImd);
    }

    function test_claimsAreDeliveredOnceTheRecipientIsUnblocked() public {
        buy(-1_000 ether);
        sell(-1_000 ether);
        uint256 pending = hook.pendingFees();
        assertGt(pending, 0);

        vm.prank(address(0xA11CE));
        vm.expectRevert();
        hook.collectPending();

        imd.setBlocked(FEE_RECIPIENT, false);
        vm.prank(address(0xA11CE));
        uint256 paid = hook.collectPending();
        assertEq(paid, pending);
        assertEq(imd.balanceOf(FEE_RECIPIENT), pending);
        assertEq(hook.pendingFees(), 0);
    }

    function test_nextSwapAfterUnblockingDeliversEverything() public {
        buy(-1_000 ether);
        uint256 pending = hook.pendingFees();
        imd.setBlocked(FEE_RECIPIENT, false);
        buy(-1_000 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), pending + uint256(1_000 ether) / 101);
        assertEq(hook.pendingFees(), 0);
    }
}

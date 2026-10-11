// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookFlags} from "../src/HookFlags.sol";
import {RNNNImdFeeHook} from "../src/RNNNImdFeeHook.sol";
import {RNNNToken} from "../src/RNNNToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(10 ether);
        buy(-int256(amountIn));

        Balances memory after_ = snapshot();
        assertEq(after_.recipientImd - before.recipientImd, 10 ether, "recipient gets exactly 1% of the IMD side");
        assertEq(before.swapperImd - after_.swapperImd, amountIn, "swapper pays exactly what they specified");
        assertEq(after_.managerImd - before.managerImd, amountIn - 10 ether, "the pool trades the other 99%");
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

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(10 ether);
        sell(int256(wantImd));

        Balances memory after_ = snapshot();
        assertEq(after_.swapperImd - before.swapperImd, wantImd, "swapper receives exactly the IMD asked for");
        assertEq(after_.recipientImd - before.recipientImd, 10 ether, "recipient gets exactly 1% of the IMD side");
        assertEq(before.managerImd - after_.managerImd, wantImd + 10 ether, "the pool pays out both");
        assertGt(before.swapperRnnn - after_.swapperRnnn, 0, "swapper paid RNNN");
    }

    // ------------------------------------------------------------------ properties

    function testFuzz_buyExactInput_feeIsAlwaysOnePercentFloor(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 100_000 ether);
        Balances memory before = snapshot();

        buy(-int256(amountIn));

        Balances memory after_ = snapshot();
        uint256 fee = after_.recipientImd - before.recipientImd;
        assertEq(fee, amountIn / 100, "fee is floor(1%)");
        assertEq(before.swapperImd - after_.swapperImd, amountIn, "swapper pays exactly amountIn");
        assertEq(after_.managerImd - before.managerImd, amountIn - fee, "IMD is conserved");
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
        assertEq(after_.recipientImd - before.recipientImd, 10 ether);
    }

    function test_feeKeepsFlowingAcrossManySwaps() public {
        uint256 start = imd.balanceOf(FEE_RECIPIENT);
        for (uint256 i = 0; i < 5; i++) {
            buy(-100 ether);
            sell(int256(100 ether));
        }
        assertEq(imd.balanceOf(FEE_RECIPIENT) - start, 10 * 1 ether, "ten swaps, 1 IMD each");
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

    function test_firstBuyDefersTheFeeAsAClaimInsteadOfReverting() public {
        Balances memory before = snapshot();

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeeDeferred(10 ether);
        buy(-1_000 ether);

        Balances memory after_ = snapshot();
        assertEq(before.swapperImd - after_.swapperImd, 1_000 ether, "the swap went through at the full amount");
        assertGt(after_.swapperRnnn, before.swapperRnnn, "the swapper received RNNN");
        assertEq(after_.recipientImd, before.recipientImd, "nothing delivered yet: the manager held no IMD");
        assertEq(hook.pendingFees(), 10 ether, "the fee is held as an ERC-6909 claim");
        assertEq(after_.managerImd, 1_000 ether, "the swapper's IMD is now in the manager");
    }

    function test_anyoneCanCollectThePendingFeeForTheRecipient() public {
        buy(-1_000 ether);
        assertEq(hook.pendingFees(), 10 ether);

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(10 ether);
        vm.prank(address(0xA11CE));
        uint256 paid = hook.collectPending();

        assertEq(paid, 10 ether);
        assertEq(imd.balanceOf(FEE_RECIPIENT), 10 ether, "the recipient received exactly 1% in IMD");
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(manager)), 990 ether);
    }

    function test_nextSwapDeliversTheDeferredFeeAlongWithItsOwn() public {
        buy(-1_000 ether);
        assertEq(hook.pendingFees(), 10 ether);

        vm.expectEmit(address(hook));
        emit RNNNImdFeeHook.FeePaid(20 ether);
        buy(-1_000 ether);

        assertEq(imd.balanceOf(FEE_RECIPIENT), 20 ether, "both fees delivered");
        assertEq(hook.pendingFees(), 0);
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

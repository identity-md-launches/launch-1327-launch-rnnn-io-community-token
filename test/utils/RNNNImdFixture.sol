// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";

import {HookFlags} from "../../src/HookFlags.sol";
import {RNNNImdFeeHook} from "../../src/RNNNImdFeeHook.sol";
import {RNNNToken} from "../../src/RNNNToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared scaffolding for the hook's invariant and ordering suites: mines the hook to its flags,
/// can place the mock IMD on either side of RNNN in the pool key, and wraps v4-core's test routers.
/// @dev Kept separate from `RNNNImdFeeHook.t.sol`'s base so that suite stays as its author left it.
abstract contract RNNNImdFixture is Test {
    /// @dev The fixed recipient the brief names.
    address constant FEE_RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;
    /// @dev Stands in for the IMD launch factory.
    address constant FACTORY = address(0xFAC7);
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant LP_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    int24 constant MIN_TICK = -887_220;
    int24 constant MAX_TICK = 887_220;

    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    /// @dev Mines a CREATE2 salt from this contract until the hook lands on an address carrying exactly
    /// `FLAGS`, the way the launch deployer does, then deploys it there.
    function deployHook(PoolManager manager_, address imd_, address recipient) internal returns (RNNNImdFeeHook) {
        bytes memory creationCode =
            abi.encodePacked(type(RNNNImdFeeHook).creationCode, abi.encode(address(manager_), imd_, recipient));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = predictCreate2(bytes32(i), initCodeHash);
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            address at = create2(creationCode, bytes32(i));
            require(at == predicted, "hook landed elsewhere");
            return RNNNImdFeeHook(at);
        }
        revert("no salt matched the flags");
    }

    /// @dev Deploys a mock IMD whose address sorts below (`imdBelow == true`) or above `rnnn`, so a suite
    /// can run the same assertions with IMD as currency0 and as currency1.
    function deployImdOrdered(address rnnn, bool imdBelow, uint256 supply) internal returns (MockERC20) {
        bytes memory creationCode = abi.encodePacked(type(MockERC20).creationCode, abi.encode("IMD", "IMD", supply));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 10_000; i++) {
            address predicted = predictCreate2(bytes32(i), initCodeHash);
            if ((predicted < rnnn) != imdBelow) continue;
            address at = create2(creationCode, bytes32(i));
            require(at == predicted, "imd landed elsewhere");
            return MockERC20(at);
        }
        revert("no salt gave the wanted ordering");
    }

    function predictCreate2(bytes32 salt, bytes32 initCodeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function create2(bytes memory creationCode, bytes32 salt) internal returns (address at) {
        assembly ("memory-safe") {
            at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(at != address(0), "create2 failed");
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

    function priceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev Full-range liquidity from `payer` through `router`, salted by payer so positions stay apart.
    /// The "no checks" router is used because v4-core's checked one `assert`s that adding liquidity never
    /// yields a positive delta, which is false once a position has accrued swap fees.
    function addFullRange(
        PoolModifyLiquidityTestNoChecks router,
        PoolKey memory key,
        address payer,
        int256 liquidityDelta
    ) internal returns (BalanceDelta) {
        vm.prank(payer);
        return router.modifyLiquidity(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, liquidityDelta, bytes32(uint256(uint160(payer)))), ""
        );
    }

    /// @dev Liquidity on the RNNN side of the 1:1 price only, the way the launch seeds its pool.
    function addRnnnOnly(
        PoolModifyLiquidityTestNoChecks router,
        PoolKey memory key,
        bool imdIsCurrency0,
        address payer,
        uint128 liquidity
    ) internal {
        (int24 lower, int24 upper) = imdIsCurrency0 ? (MIN_TICK, -TICK_SPACING) : (TICK_SPACING, MAX_TICK);
        vm.prank(payer);
        router.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(uint256(uint160(payer)))), ""
        );
    }

    function swapAs(PoolSwapTest router, PoolKey memory key, address actor, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta)
    {
        SwapParams memory params = SwapParams(zeroForOne, amountSpecified, priceLimit(zeroForOne));
        vm.prank(actor);
        return router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    function approveAll(address owner, RNNNToken rnnn, MockERC20 imd, address[] memory spenders) internal {
        vm.startPrank(owner);
        for (uint256 i = 0; i < spenders.length; i++) {
            rnnn.approve(spenders[i], type(uint256).max);
            imd.approve(spenders[i], type(uint256).max);
        }
        vm.stopPrank();
    }
}

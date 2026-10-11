// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DeployRNNN} from "../script/Deploy.s.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {RNNNImdFeeHook} from "../src/RNNNImdFeeHook.sol";
import {RNNNToken} from "../src/RNNNToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployTest is Test {
    function test_deployPlacesTheHookOnAFlaggedAddressWithTheGivenArguments() public {
        PoolManager manager = new PoolManager(address(this));
        MockERC20 imd = new MockERC20("IMD", "IMD", 0);
        DeployRNNN deployer = new DeployRNNN();

        DeployRNNN.Config memory cfg = DeployRNNN.Config({
            poolManager: IPoolManager(address(manager)), imd: address(imd), feeRecipient: deployer.FEE_RECIPIENT()
        });
        (RNNNToken token, RNNNImdFeeHook hook) = deployer.deploy(cfg, address(deployer));

        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 ether, "the deployer holds the supply");
        assertEq(HookFlags.flagsOf(address(hook)), deployer.HOOK_FLAGS());
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.feeRecipient(), 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4);
    }
}

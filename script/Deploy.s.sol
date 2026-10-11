// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {RNNNImdFeeHook} from "../src/RNNNImdFeeHook.sol";
import {RNNNToken} from "../src/RNNNToken.sol";

/// @title DeployRNNN
/// @notice Rehearsal deployment of the RNNN token and its IMD fee hook.
/// @dev On the real launch the IMD factory deploys both contracts from their bytecode, mines the
/// hook's salt and opens the pool itself; this script exists to rehearse that on a local or test
/// chain and to document the constructor arguments. `run()` reads its configuration from the
/// environment and hands it to `deploy`, which tests call directly with their own values.
contract DeployRNNN is Script {
    /// @notice The fee recipient the brief fixes. Not configurable.
    address public constant FEE_RECIPIENT = 0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4;

    /// @notice IMD on Robinhood Chain (chain id 4663), the pool's pair currency.
    address public constant IMD_ROBINHOOD_CHAIN = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    /// @notice Forge's deterministic CREATE2 deployer, through which broadcast `new {salt: ...}`
    /// deployments go.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    struct Config {
        IPoolManager poolManager;
        address imd;
        address feeRecipient;
    }

    /// @dev Environment: POOL_MANAGER (the chain's Uniswap v4 PoolManager) and optionally IMD
    /// (defaults to IMD on Robinhood Chain).
    function run() external returns (RNNNToken token, RNNNImdFeeHook hook) {
        Config memory cfg = Config({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            imd: vm.envOr("IMD", IMD_ROBINHOOD_CHAIN),
            feeRecipient: FEE_RECIPIENT
        });
        vm.startBroadcast();
        (token, hook) = deploy(cfg, CREATE2_DEPLOYER);
        vm.stopBroadcast();
    }

    /// @notice Deploy the token and the hook, the hook at an address carrying `HOOK_FLAGS`.
    /// @param cfg Constructor arguments for the hook.
    /// @param create2Deployer The address CREATE2 runs from: `CREATE2_DEPLOYER` under broadcast, the
    /// script contract itself when called in a test.
    function deploy(Config memory cfg, address create2Deployer) public returns (RNNNToken token, RNNNImdFeeHook hook) {
        token = new RNNNToken();
        bytes32 salt = mineSalt(cfg, create2Deployer);
        hook = new RNNNImdFeeHook{salt: salt}(cfg.poolManager, cfg.imd, cfg.feeRecipient);
        require(HookFlags.matches(address(hook), HOOK_FLAGS), "hook address does not carry the flags");
    }

    /// @notice Find a salt whose CREATE2 address from `create2Deployer` carries exactly `HOOK_FLAGS`.
    function mineSalt(Config memory cfg, address create2Deployer) public pure returns (bytes32) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(RNNNImdFeeHook).creationCode, abi.encode(cfg.poolManager, cfg.imd, cfg.feeRecipient))
        );
        for (uint256 i = 0; i < 1_000_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, HOOK_FLAGS)) return bytes32(i);
        }
        revert("no salt found");
    }
}

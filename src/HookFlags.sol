// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookFlags
/// @notice The Uniswap v4 hook permission bits as they appear in a hook's address, plus helpers to
/// compare an address against a set of declared flags.
/// @dev Every function is `internal` so the compiler inlines it and no contract that uses the
/// library carries a link placeholder in its bytecode.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice Mask of all fourteen permission bits.
    uint160 internal constant ALL = uint160((1 << 14) - 1);

    /// @notice The permission bits carried by `hook`'s address.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook`'s address carries exactly `flags` (within the permission mask).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}

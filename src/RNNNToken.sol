// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RNNNToken
/// @notice RNNN, the rnnn.io community token: a plain fixed-supply ERC-20.
/// @dev Exactly 1,000,000,000 tokens with 18 decimals are minted once, to the deployer (the IMD
/// launch factory), in the constructor. There is no owner, no mint, no burn, no pause, no blocklist,
/// no fee and no upgrade path. The swap fee the launch asks for lives in `RNNNImdFeeHook`.
contract RNNNToken {
    string public constant name = "RNNN";
    string public constant symbol = "RNNN";
    uint8 public constant decimals = 18;

    /// @notice The whole supply, minted once in the constructor: 10^27 minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public immutable totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(uint256 available, uint256 requested);
    error InsufficientAllowance(uint256 available, uint256 requested);
    error ZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance(allowed, value);
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance(fromBalance, value);
        unchecked {
            balanceOf[from] = fromBalance - value;
            // Total supply is fixed, so the sum of balances never exceeds it and cannot overflow.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}

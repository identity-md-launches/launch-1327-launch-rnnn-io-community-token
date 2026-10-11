// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RNNNToken} from "../src/RNNNToken.sol";

/// @notice Moves RNNN between a fixed set of holders in random order: transfers, approvals, transferFrom,
/// self-transfers, and attempts that must fail (over balance, over allowance, to the zero address).
contract RNNNTokenHandler is Test {
    RNNNToken public token;
    address[] public holders;
    mapping(bytes32 => uint256) public calls;

    uint256 public ghost_rejectedTransfers;
    uint256 public ghost_rejectedTransferFroms;

    constructor(RNNNToken token_, address[] memory holders_) {
        token = token_;
        holders = holders_;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls["transfer"]++;
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, 0, balance);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        if (from == to) {
            assertEq(token.balanceOf(from), balance, "self-transfer leaves the balance alone");
        } else {
            assertEq(token.balanceOf(from), balance - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }

    function transferOverBalanceReverts(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        calls["transferOverBalanceReverts"]++;
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(RNNNToken.InsufficientBalance.selector, balance, balance + excess));
        token.transfer(to, balance + excess);
        ghost_rejectedTransfers++;
        assertEq(token.balanceOf(from), balance);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        calls["approve"]++;
        address owner = holders[ownerSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        calls["transferFrom"]++;
        address owner = holders[ownerSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        uint256 cap = allowed < balance ? allowed : balance;
        amount = bound(amount, 0, cap);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));

        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance is not spent");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance is spent exactly");
        }
        if (owner != to) {
            assertEq(token.balanceOf(owner), balance - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }

    function transferFromOverAllowanceReverts(uint256 ownerSeed, uint256 spenderSeed, uint256 excess) external {
        calls["transferFromOverAllowanceReverts"]++;
        address owner = holders[ownerSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return;
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 balance = token.balanceOf(owner);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(RNNNToken.InsufficientAllowance.selector, allowed, allowed + excess));
        token.transferFrom(owner, spender, allowed + excess);
        ghost_rejectedTransferFroms++;
        assertEq(token.balanceOf(owner), balance);
        assertEq(token.allowance(owner, spender), allowed);
    }

    function transferToZeroReverts(uint256 fromSeed, uint256 amount) external {
        calls["transferToZeroReverts"]++;
        address from = holders[fromSeed % holders.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        vm.expectRevert(RNNNToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
    }
}

/// @notice RNNN is a fixed-supply ledger: whatever sequence of transfers and approvals happens, the supply
/// is constant, the holders' balances always sum to it, and nothing ever lands at the zero address.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract RNNNTokenInvariants is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    RNNNToken token;
    RNNNTokenHandler handler;
    address[] holders;

    function setUp() public {
        token = new RNNNToken();
        holders.push(address(this));
        holders.push(makeAddr("alice"));
        holders.push(makeAddr("bob"));
        holders.push(makeAddr("carol"));
        holders.push(makeAddr("dave"));
        // Spread some supply so the first calls have something to move.
        for (uint256 i = 1; i < holders.length; i++) {
            token.transfer(holders[i], 1_000_000 ether * i);
        }
        handler = new RNNNTokenHandler(token, holders);
        targetContract(address(handler));
    }

    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function invariant_balancesSumToTheSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < holders.length; i++) {
            sum += token.balanceOf(holders[i]);
        }
        assertEq(sum, SUPPLY, "tokens were created or destroyed");
    }

    function invariant_nothingAtTheZeroAddress() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_noHolderExceedsTheSupply() public view {
        for (uint256 i = 0; i < holders.length; i++) {
            assertLe(token.balanceOf(holders[i]), SUPPLY);
        }
    }
}

/// @notice Stateless edges of the token that the unit suite does not pin.
contract RNNNTokenEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    RNNNToken token;

    function setUp() public {
        token = new RNNNToken();
    }

    function test_transferOfTheWholeBalanceLeavesZero() public {
        address to = makeAddr("to");
        token.transfer(to, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(to), SUPPLY);
    }

    function test_transferOfOneWeiMoreThanTheBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RNNNToken.InsufficientBalance.selector, SUPPLY, SUPPLY + 1));
        token.transfer(makeAddr("to"), SUPPLY + 1);
    }

    function test_zeroValueTransferSucceedsAndEmits() public {
        address to = makeAddr("to");
        vm.expectEmit(address(token));
        emit RNNNToken.Transfer(address(this), to, 0);
        assertTrue(token.transfer(to, 0));
    }

    function test_selfTransferKeepsTheBalance() public {
        assertTrue(token.transfer(address(this), 1_000 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferFromToZeroAddressReverts() public {
        address spender = makeAddr("spender");
        token.approve(spender, 1 ether);
        vm.prank(spender);
        vm.expectRevert(RNNNToken.ZeroAddress.selector);
        token.transferFrom(address(this), address(0), 1 ether);
    }

    function test_transferFromWithoutAnyAllowanceReverts() public {
        address spender = makeAddr("spender");
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(RNNNToken.InsufficientAllowance.selector, 0, 1));
        token.transferFrom(address(this), spender, 1);
    }

    function test_allowanceCanBeLoweredAndRaised() public {
        address spender = makeAddr("spender");
        token.approve(spender, 5 ether);
        token.approve(spender, 1 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        token.approve(spender, 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferFromSpendsExactlyTheAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, type(uint256).max - 1); // below the infinite sentinel
        amount = bound(amount, 0, allowance < SUPPLY ? allowance : SUPPLY);
        address spender = makeAddr("spender");
        token.approve(spender, allowance);
        vm.prank(spender);
        token.transferFrom(address(this), spender, amount);
        assertEq(token.allowance(address(this), spender), allowance - amount);
        assertEq(token.balanceOf(spender), amount);
    }
}

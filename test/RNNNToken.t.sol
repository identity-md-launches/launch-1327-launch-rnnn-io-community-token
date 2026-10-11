// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RNNNToken} from "../src/RNNNToken.sol";

contract RNNNTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    RNNNToken token;

    function setUp() public {
        token = new RNNNToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "RNNN");
        assertEq(token.symbol(), "RNNN");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        address to = address(0xCAFE);
        assertTrue(token.transfer(to, 1_000 ether));
        assertEq(token.balanceOf(to), 1_000 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(RNNNToken.InsufficientBalance.selector, 0, 1));
        token.transfer(address(this), 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(RNNNToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        address spender = address(0x5BE4D);
        address to = address(0xCAFE);
        assertTrue(token.approve(spender, 500 ether));
        assertEq(token.allowance(address(this), spender), 500 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), to, 200 ether));
        assertEq(token.balanceOf(to), 200 ether);
        assertEq(token.allowance(address(this), spender), 300 ether);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(RNNNToken.InsufficientAllowance.selector, 300 ether, 301 ether));
        token.transferFrom(address(this), to, 301 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        address spender = address(0x5BE4D);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), address(0xCAFE), 1 ether);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
    }

    function test_noMintOwnerPauseOrUpgradePath() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(0xBEEF), uint256(1));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
        }
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}

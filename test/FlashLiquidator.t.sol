// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {FlashLiquidator, ISwapper} from "../src/periphery/FlashLiquidator.sol";
import {MockSwapper} from "../src/mocks/Mocks.sol";
import {IMeridian} from "../src/interfaces/IMeridian.sol";

contract FlashLiquidatorTest is BaseTest {
    FlashLiquidator internal liquidator;
    MockSwapper internal swapper;

    function setUp() public override {
        super.setUp();
        vm.prank(LIQUIDATOR);
        liquidator = new FlashLiquidator(IMeridian(address(meridian)));
        swapper = new MockSwapper(oracle, 50); // 0.5% slippage

        _supply(SUPPLIER, 100_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 25_000e6);
        oracle.setPrice(2_800e24);
    }

    function test_flashLiquidation_isProfitableWithZeroCapital() public {
        assertEq(usdc.balanceOf(LIQUIDATOR), 0);
        vm.prank(LIQUIDATOR);
        uint256 profit = liquidator.liquidate(params, BORROWER, 4 ether, ISwapper(address(swapper)), 1e6);
        assertGt(profit, 1e6);
        assertEq(usdc.balanceOf(LIQUIDATOR), profit);
        assertGe(meridian.healthFactor(params, BORROWER), 1e18);
    }

    function test_flashLiquidation_revertsIfUnprofitable() public {
        MockSwapper bad = new MockSwapper(oracle, 900); // 9% slippage > 4.4% incentive
        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        liquidator.liquidate(params, BORROWER, 3 ether, ISwapper(address(bad)), 0);
    }

    function test_onlyOwner() public {
        vm.expectRevert(FlashLiquidator.NotOwner.selector);
        liquidator.liquidate(params, BORROWER, 1 ether, ISwapper(address(swapper)), 0);
    }

    function test_callbackOnlyFromMeridian() public {
        vm.expectRevert(FlashLiquidator.NotMeridian.selector);
        liquidator.onMeridianLiquidate(1, "");
    }
}

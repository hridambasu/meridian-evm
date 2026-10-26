// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracleAdapter, AggregatorV3Interface} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {NavOracle} from "../src/oracles/NavOracle.sol";
import {MockAggregator} from "../src/mocks/Mocks.sol";

contract OraclesTest is Test {
    function setUp() public {
        vm.warp(1_700_000_000);
    }

    function test_chainlink_scalesDecimals() public {
        // ETH/USD feed (8 dec) = 3000, USDC/USD feed (8 dec) = 1.0, WETH 18 dec, USDC 6 dec
        MockAggregator ethUsd = new MockAggregator(8, 3000e8);
        MockAggregator usdcUsd = new MockAggregator(8, 1e8);
        ChainlinkOracleAdapter o = new ChainlinkOracleAdapter(
            AggregatorV3Interface(address(ethUsd)), AggregatorV3Interface(address(usdcUsd)), 18, 6, 1 hours
        );
        assertEq(o.price(), 3000e24);
    }

    function test_chainlink_revertsWhenStale() public {
        MockAggregator ethUsd = new MockAggregator(8, 3000e8);
        ChainlinkOracleAdapter o =
            new ChainlinkOracleAdapter(AggregatorV3Interface(address(ethUsd)), AggregatorV3Interface(address(0)), 18, 6, 1 hours);
        skip(2 hours);
        vm.expectRevert(ChainlinkOracleAdapter.StalePrice.selector);
        o.price();
    }

    function test_chainlink_revertsOnNonPositive() public {
        MockAggregator ethUsd = new MockAggregator(8, 3000e8);
        ChainlinkOracleAdapter o =
            new ChainlinkOracleAdapter(AggregatorV3Interface(address(ethUsd)), AggregatorV3Interface(address(0)), 18, 6, 1 hours);
        ethUsd.set(0, block.timestamp);
        vm.expectRevert(ChainlinkOracleAdapter.NegativePrice.selector);
        o.price();
    }

    function test_nav_priceWithHaircut() public {
        address updater = makeAddr("updater");
        // tBILL (6 dec) NAV = 1.05 USDC (6 dec), 2% haircut
        NavOracle o = new NavOracle(updater, 1.05e18, 6, 6, 1 days, 100, 200);
        assertEq(o.price(), uint256(1.05e36) * 98 / 100);
    }

    function test_nav_deviationGuard() public {
        address updater = makeAddr("updater");
        NavOracle o = new NavOracle(updater, 1e18, 6, 6, 1 days, 100, 0); // max 1% move
        vm.startPrank(updater);
        o.updateNav(1.009e18);
        vm.expectRevert(NavOracle.DeviationTooLarge.selector);
        o.updateNav(1.03e18);
        vm.stopPrank();
    }

    function test_nav_staleReverts() public {
        NavOracle o = new NavOracle(address(this), 1e18, 6, 6, 1 days, 100, 0);
        skip(1 days + 1);
        vm.expectRevert(NavOracle.StaleNav.selector);
        o.price();
    }

    function test_nav_onlyUpdater() public {
        NavOracle o = new NavOracle(makeAddr("updater"), 1e18, 6, 6, 1 days, 100, 0);
        vm.expectRevert(NavOracle.NotUpdater.selector);
        o.updateNav(1e18);
    }
}

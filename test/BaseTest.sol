// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Meridian} from "../src/Meridian.sol";
import {AdaptiveCurveIrm} from "../src/irm/AdaptiveCurveIrm.sol";
import {FixedRateIrm} from "../src/irm/FixedRateIrm.sol";
import {MockERC20, MockOracle} from "../src/mocks/Mocks.sol";
import {MarketParams, Id, MarketParamsLib, IMeridian} from "../src/interfaces/IMeridian.sol";

abstract contract BaseTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant LLTV = 0.86e18;
    /// 1 WETH (18 dec) = 3000 USDC (6 dec) => 3000 * 1e6 / 1e18 * 1e36
    uint256 internal constant ETH_PRICE = 3000e24;

    address internal OWNER = makeAddr("owner");
    address internal FEE_RECIPIENT = makeAddr("feeRecipient");
    address internal SUPPLIER = makeAddr("supplier");
    address internal BORROWER = makeAddr("borrower");
    address internal LIQUIDATOR = makeAddr("liquidator");

    Meridian internal meridian;
    AdaptiveCurveIrm internal irm;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockOracle internal oracle;
    MarketParams internal params;
    Id internal id;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        meridian = new Meridian(OWNER);
        irm = new AdaptiveCurveIrm(address(meridian));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(ETH_PRICE);

        vm.startPrank(OWNER);
        meridian.enableIrm(address(irm));
        meridian.enableLltv(LLTV);
        meridian.setFeeRecipient(FEE_RECIPIENT);
        vm.stopPrank();

        params = MarketParams(address(usdc), address(weth), address(oracle), address(irm), LLTV);
        id = params.id();
        meridian.createMarket(params);

        _approveAll(SUPPLIER);
        _approveAll(BORROWER);
        _approveAll(LIQUIDATOR);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(meridian), type(uint256).max);
        weth.approve(address(meridian), type(uint256).max);
        vm.stopPrank();
    }

    function _supply(address who, uint256 assets) internal {
        usdc.mint(who, assets);
        vm.prank(who);
        meridian.supply(params, assets, 0, who, "");
    }

    function _depositCollateral(address who, uint256 assets) internal {
        weth.mint(who, assets);
        vm.prank(who);
        meridian.supplyCollateral(params, assets, who, "");
    }

    function _borrow(address who, uint256 assets) internal {
        vm.prank(who);
        meridian.borrow(params, assets, 0, who, who);
    }

    function _market()
        internal
        view
        returns (uint256 tsa, uint256 tss, uint256 tba, uint256 tbs, uint256 lastUpdate, uint256 fee)
    {
        (uint128 a, uint128 b, uint128 c, uint128 d, uint128 e, uint128 f) = meridian.market(id);
        return (a, b, c, d, e, f);
    }

    function _position(address who) internal view returns (uint256 supplyShares, uint256 borrowShares, uint256 col) {
        (uint256 a, uint128 b, uint128 c) = meridian.position(id, who);
        return (a, b, c);
    }
}

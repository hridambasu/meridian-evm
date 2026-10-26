// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {Meridian} from "../src/Meridian.sol";
import {MarketParams, MarketParamsLib} from "../src/interfaces/IMeridian.sol";
import {FixedRateIrm} from "../src/irm/FixedRateIrm.sol";

contract MeridianTest is BaseTest {
    using MarketParamsLib for MarketParams;

    /* ----------------------------- market setup ----------------------------- */

    function test_createMarket_revertsForUnapprovedIrm() public {
        MarketParams memory p = params;
        p.irm = address(0xdead);
        vm.expectRevert(Meridian.IrmNotEnabled.selector);
        meridian.createMarket(p);
    }

    function test_createMarket_revertsForUnapprovedLltv() public {
        MarketParams memory p = params;
        p.lltv = 0.99e18;
        vm.expectRevert(Meridian.LltvNotEnabled.selector);
        meridian.createMarket(p);
    }

    function test_createMarket_revertsIfExists() public {
        vm.expectRevert(Meridian.MarketAlreadyCreated.selector);
        meridian.createMarket(params);
    }

    /* ---------------------------- supply/withdraw --------------------------- */

    function test_supplyAndWithdraw() public {
        _supply(SUPPLIER, 1_000e6);
        (uint256 tsa,,,,,) = _market();
        assertEq(tsa, 1_000e6);

        vm.prank(SUPPLIER);
        meridian.withdraw(params, 400e6, 0, SUPPLIER, SUPPLIER);
        assertEq(usdc.balanceOf(SUPPLIER), 400e6);
    }

    function test_withdraw_onlyAuthorized() public {
        _supply(SUPPLIER, 1_000e6);
        vm.prank(BORROWER);
        vm.expectRevert(Meridian.Unauthorized.selector);
        meridian.withdraw(params, 1e6, 0, SUPPLIER, BORROWER);

        vm.prank(SUPPLIER);
        meridian.setAuthorization(BORROWER, true);
        vm.prank(BORROWER);
        meridian.withdraw(params, 1e6, 0, SUPPLIER, BORROWER);
        assertEq(usdc.balanceOf(BORROWER), 1e6);
    }

    function test_withdraw_cannotExceedLiquidity() public {
        _supply(SUPPLIER, 1_000e6);
        _depositCollateral(BORROWER, 1 ether);
        _borrow(BORROWER, 900e6);
        vm.prank(SUPPLIER);
        vm.expectRevert(Meridian.InsufficientLiquidity.selector);
        meridian.withdraw(params, 200e6, 0, SUPPLIER, SUPPLIER);
    }

    function test_inputMustSetExactlyOneOfAssetsOrShares() public {
        usdc.mint(SUPPLIER, 10e6);
        vm.startPrank(SUPPLIER);
        vm.expectRevert(Meridian.InconsistentInput.selector);
        meridian.supply(params, 1e6, 1e6, SUPPLIER, "");
        vm.expectRevert(Meridian.InconsistentInput.selector);
        meridian.supply(params, 0, 0, SUPPLIER, "");
        vm.stopPrank();
    }

    /* ------------------------------ borrow/repay ---------------------------- */

    function test_borrow_withinLltv() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 1 ether); // $3000, max borrow = 2580
        _borrow(BORROWER, 2_580e6);
        assertEq(usdc.balanceOf(BORROWER), 2_580e6);
    }

    function test_borrow_revertsAboveLltv() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 1 ether);
        vm.prank(BORROWER);
        vm.expectRevert(Meridian.InsufficientCollateral.selector);
        meridian.borrow(params, 2_581e6, 0, BORROWER, BORROWER);
    }

    function test_withdrawCollateral_revertsIfUnhealthy() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 1 ether);
        _borrow(BORROWER, 2_000e6);
        vm.prank(BORROWER);
        vm.expectRevert(Meridian.InsufficientCollateral.selector);
        meridian.withdrawCollateral(params, 0.5 ether, BORROWER, BORROWER);
    }

    function test_repayFullByShares_clearsDebt() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 1 ether);
        _borrow(BORROWER, 1_000e6);
        skip(30 days);

        (, uint256 borrowShares,) = _position(BORROWER);
        usdc.mint(BORROWER, 100e6); // cover interest
        vm.prank(BORROWER);
        (uint256 repaid,) = meridian.repay(params, 0, borrowShares, BORROWER, "");
        assertGt(repaid, 1_000e6, "interest accrued");

        (, uint256 bs,) = _position(BORROWER);
        assertEq(bs, 0);
        vm.prank(BORROWER);
        meridian.withdrawCollateral(params, 1 ether, BORROWER, BORROWER);
    }

    /* ------------------------------- interest ------------------------------- */

    function test_interestAccrues_toSuppliers() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 9_000e6); // 90% = target utilization

        skip(365 days);
        meridian.accrueInterest(params);

        uint256 supplierAssets = meridian.expectedSupplyAssets(params, SUPPLIER);
        assertGt(supplierAssets, 10_000e6);
        // At target utilisation the rate stays near the 4% initial rate-at-target.
        uint256 debt = meridian.expectedBorrowAssets(params, BORROWER);
        uint256 apr = (debt - 9_000e6) * 1e18 / 9_000e6;
        assertApproxEqRel(apr, 0.0408e18, 0.02e18); // e^0.04 - 1 ~= 4.08%
    }

    function test_expectedBalances_matchAccrual() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 5_000e6);
        skip(100 days);

        (uint256 eTsa,, uint256 eTba,) = meridian.expectedMarketBalances(params);
        meridian.accrueInterest(params);
        (uint256 tsa,, uint256 tba,,,) = _market();
        assertEq(eTsa, tsa);
        assertEq(eTba, tba);
    }

    function test_protocolFee_mintsSharesToRecipient() public {
        vm.prank(OWNER);
        meridian.setFee(params, 0.1e18);

        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 8_000e6);
        skip(365 days);
        meridian.accrueInterest(params);

        uint256 debt = meridian.expectedBorrowAssets(params, BORROWER);
        uint256 interest = debt - 8_000e6;
        uint256 feeAssets = meridian.expectedSupplyAssets(params, FEE_RECIPIENT);
        assertApproxEqRel(feeAssets, interest / 10, 0.001e18);
    }

    function test_fixedRateIrm_chargesExactApr() public {
        FixedRateIrm fixedIrm = new FixedRateIrm(0.06e18);
        vm.prank(OWNER);
        meridian.enableIrm(address(fixedIrm));

        params.irm = address(fixedIrm);
        id = params.id();
        meridian.createMarket(params);

        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 1_000e6);
        skip(365 days);

        uint256 debt = meridian.expectedBorrowAssets(params, BORROWER);
        assertApproxEqRel(debt, 1_061.8e6, 0.001e18); // e^0.06
    }

    /* ------------------------------ liquidation ----------------------------- */

    function test_liquidationIncentiveFactor() public view {
        // lltv 86% => 1 / (1 - 0.3 * 0.14) = 1.0438...
        assertApproxEqAbs(meridian.liquidationIncentiveFactor(0.86e18), 1.043841336e18, 1e9);
        // low lltv is capped at 15%
        assertEq(meridian.liquidationIncentiveFactor(0.3e18), 1.15e18);
    }

    function test_liquidate_revertsOnHealthy() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 1 ether);
        _borrow(BORROWER, 2_000e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(Meridian.HealthyPosition.selector);
        meridian.liquidate(params, BORROWER, 0.1 ether, 0, "");
    }

    function test_liquidate_partial() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 1 ether);
        _borrow(BORROWER, 2_500e6);

        oracle.setPrice(2_800e24); // max borrow = 2408 < 2500
        assertLt(meridian.healthFactor(params, BORROWER), 1e18);

        usdc.mint(LIQUIDATOR, 10_000e6);
        vm.prank(LIQUIDATOR);
        (uint256 seized, uint256 repaid) = meridian.liquidate(params, BORROWER, 0.5 ether, 0, "");

        assertEq(seized, 0.5 ether);
        assertEq(weth.balanceOf(LIQUIDATOR), 0.5 ether);
        // repaid ~= 0.5 * 2800 / LIF
        uint256 lif = meridian.liquidationIncentiveFactor(LLTV);
        assertApproxEqAbs(repaid, uint256(1_400e6) * 1e18 / lif, 2);
        assertGe(meridian.healthFactor(params, BORROWER), 1e18, "position restored");
    }

    function test_liquidate_realisesBadDebt() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 1 ether);
        _borrow(BORROWER, 2_500e6);

        oracle.setPrice(2_000e24); // collateral worth less than debt
        usdc.mint(LIQUIDATOR, 10_000e6);
        vm.prank(LIQUIDATOR);
        meridian.liquidate(params, BORROWER, 1 ether, 0, "");

        (, uint256 borrowShares, uint256 col) = _position(BORROWER);
        assertEq(col, 0);
        assertEq(borrowShares, 0, "bad debt written off");

        (uint256 tsa,, uint256 tba,,,) = _market();
        assertEq(tba, 0);
        assertLt(tsa, 10_000e6, "suppliers absorb the loss");
        assertApproxEqAbs(tsa, 10_000e6 - 2_500e6 + uint256(2_000e6) * 1e18 / meridian.liquidationIncentiveFactor(LLTV), 2);
    }

    /* ---------------------------------- fuzz -------------------------------- */

    function testFuzz_borrowNeverExceedsLltv(uint256 collateral, uint256 borrowAmt) public {
        collateral = bound(collateral, 1e12, 1_000 ether);
        _supply(SUPPLIER, 100_000_000e6);
        _depositCollateral(BORROWER, collateral);

        uint256 maxBorrow = collateral * ETH_PRICE / 1e36 * LLTV / 1e18;
        borrowAmt = bound(borrowAmt, 1, maxBorrow * 2 + 1);

        vm.prank(BORROWER);
        if (borrowAmt > maxBorrow) {
            vm.expectRevert(Meridian.InsufficientCollateral.selector);
            meridian.borrow(params, borrowAmt, 0, BORROWER, BORROWER);
        } else {
            meridian.borrow(params, borrowAmt, 0, BORROWER, BORROWER);
            assertGe(meridian.healthFactor(params, BORROWER), 1e18);
        }
    }

    function testFuzz_supplyWithdrawRoundTripNeverProfits(uint256 assets) public {
        assets = bound(assets, 1, 1e15);
        _supply(SUPPLIER, 1_000e6); // existing liquidity
        address alice = makeAddr("alice");
        _approveAll(alice);
        _supply(alice, assets);
        (uint256 shares,,) = _position(alice);
        vm.prank(alice);
        (uint256 out,) = meridian.withdraw(params, 0, shares, alice, alice);
        assertLe(out, assets, "rounding favours the protocol");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {ExpLib} from "../src/libraries/MathLib.sol";

contract IrmTest is BaseTest {
    function test_wExp_accuracy() public pure {
        assertApproxEqRel(ExpLib.wExp(0), 1e18, 1e10);
        assertApproxEqRel(ExpLib.wExp(1e18), 2.718281828e18, 1e13);
        assertApproxEqRel(ExpLib.wExp(-1e18), 0.367879441e18, 1e13);
        assertApproxEqRel(ExpLib.wExp(5e18), 148.413159102e18, 1e13);
        assertEq(ExpLib.wExp(-50e18), 0);
    }

    function test_rateRises_whenUtilisationAboveTarget() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 9_900e6); // 99% utilisation

        int256 start = irm.rateAtTarget(id);
        skip(5 days);
        meridian.accrueInterest(params);
        int256 end = irm.rateAtTarget(id);
        // err = (0.99-0.9)/0.1 = 0.9 => e^(50*0.9*5/365) ~= 1.85x
        assertApproxEqRel(uint256(end), uint256(start) * 185 / 100, 0.02e18);
    }

    function test_rateFalls_whenUtilisationBelowTarget() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 1_000e6); // 10%

        int256 start = irm.rateAtTarget(id);
        skip(10 days);
        meridian.accrueInterest(params);
        assertLt(irm.rateAtTarget(id), start);
    }

    function test_rateAtTarget_isBounded() public {
        _supply(SUPPLIER, 10_000e6);
        _depositCollateral(BORROWER, 10 ether);
        _borrow(BORROWER, 10_000e6); // 100%

        skip(365 days);
        meridian.accrueInterest(params);
        assertEq(irm.rateAtTarget(id), irm.MAX_RATE_AT_TARGET());
    }

    function test_onlyMeridianCanMutate() public {
        vm.expectRevert();
        irm.borrowRate(params, _emptyMarket());
    }

    function _emptyMarket() internal pure returns (Market memory m) {}
}

import {Market} from "../src/interfaces/IMeridian.sol";

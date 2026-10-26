// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIrm, MarketParams, Market, Id, MarketParamsLib} from "../interfaces/IMeridian.sol";
import {ExpLib, WAD} from "../libraries/MathLib.sol";

/// @title AdaptiveCurveIrm
/// @notice Interest rate model that (1) applies a kinked curve around a target
/// utilization and (2) continuously moves the whole curve up or down depending on
/// how long utilization stays away from target. This removes the need for
/// governance to hand-tune rates per market: markets "discover" their own price
/// of liquidity, which is what makes permissionless isolated markets workable.
///
///   rate(u) = rateAtTarget * curve(err(u))
///   d(rateAtTarget)/dt = rateAtTarget * ADJUSTMENT_SPEED * err(u)
contract AdaptiveCurveIrm is IIrm {
    using MarketParamsLib for MarketParams;

    int256 internal constant WAD_INT = 1e18;

    /// @notice Curve steepness: rate at 100% utilisation = 4x rateAtTarget; at 0% = 1/4x.
    int256 public constant CURVE_STEEPNESS = 4e18;
    /// @notice At err = 1 (fully utilised) rateAtTarget grows by e^50 per year (i.e. doubles in ~5 days).
    int256 public constant ADJUSTMENT_SPEED = 50e18 / int256(365 days);
    int256 public constant TARGET_UTILIZATION = 0.9e18;
    int256 public constant INITIAL_RATE_AT_TARGET = 0.04e18 / int256(365 days);
    int256 public constant MIN_RATE_AT_TARGET = 0.001e18 / int256(365 days);
    int256 public constant MAX_RATE_AT_TARGET = 2.0e18 / int256(365 days);

    address public immutable MERIDIAN;
    mapping(Id => int256) public rateAtTarget;

    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    error NotMeridian();

    constructor(address meridian) {
        MERIDIAN = meridian;
    }

    function borrowRateView(MarketParams memory params, Market memory m) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(params.id(), m);
        return avgRate;
    }

    function borrowRate(MarketParams memory params, Market memory m) external returns (uint256) {
        if (msg.sender != MERIDIAN) revert NotMeridian();
        Id id = params.id();
        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, m);
        rateAtTarget[id] = endRateAtTarget;
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));
        return avgRate;
    }

    /// @return avgRate Average per-second rate over the elapsed period (trapezoid rule).
    /// @return endRateAtTarget rateAtTarget to persist.
    function _borrowRate(Id id, Market memory m) internal view returns (uint256, int256) {
        int256 utilization =
            m.totalSupplyAssets > 0 ? int256(uint256(m.totalBorrowAssets) * WAD / m.totalSupplyAssets) : int256(0);

        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD_INT - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = (utilization - TARGET_UTILIZATION) * WAD_INT / errNormFactor;

        int256 startRateAtTarget = rateAtTarget[id];
        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction with this market.
            avgRateAtTarget = INITIAL_RATE_AT_TARGET;
            endRateAtTarget = INITIAL_RATE_AT_TARGET;
        } else {
            int256 speed = ADJUSTMENT_SPEED * err / WAD_INT;
            int256 elapsed = int256(block.timestamp - uint256(m.lastUpdate));
            int256 linearAdaptation = speed * elapsed;

            if (linearAdaptation == 0) {
                avgRateAtTarget = startRateAtTarget;
                endRateAtTarget = startRateAtTarget;
            } else {
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        return (uint256(_curve(avgRateAtTarget, err)), endRateAtTarget);
    }

    function _curve(int256 _rateAtTarget, int256 err) internal pure returns (int256) {
        int256 coeff = err < 0 ? WAD_INT - WAD_INT * WAD_INT / CURVE_STEEPNESS : CURVE_STEEPNESS - WAD_INT;
        return ((coeff * err / WAD_INT) + WAD_INT) * _rateAtTarget / WAD_INT;
    }

    function _newRateAtTarget(int256 start, int256 linearAdaptation) internal pure returns (int256) {
        int256 r = start * ExpLib.wExp(linearAdaptation) / WAD_INT;
        if (r < MIN_RATE_AT_TARGET) return MIN_RATE_AT_TARGET;
        if (r > MAX_RATE_AT_TARGET) return MAX_RATE_AT_TARGET;
        return r;
    }
}

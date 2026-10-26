// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIrm, MarketParams, Market} from "../interfaces/IMeridian.sol";

/// @title FixedRateIrm
/// @notice Constant borrow rate for credit products where borrowers need rate
/// certainty, e.g. borrowing stablecoins against tokenized T-bills / private
/// credit. One deployment per rate tier (e.g. 5%, 7%, 9% APR); governance
/// enables each tier, and the rate becomes part of the market's identity
/// because the IRM address is in MarketParams. No one can change it later.
contract FixedRateIrm is IIrm {
    uint256 public constant MAX_RATE = 1e18 / uint256(365 days); // 100% APR cap
    uint256 public immutable RATE_PER_SECOND;

    error InvalidRate();

    constructor(uint256 aprWad) {
        uint256 r = aprWad / 365 days;
        if (r == 0 || r > MAX_RATE) revert InvalidRate();
        RATE_PER_SECOND = r;
    }

    function borrowRateView(MarketParams memory, Market memory) public view returns (uint256) {
        return RATE_PER_SECOND;
    }

    function borrowRate(MarketParams memory, Market memory) external view returns (uint256) {
        return RATE_PER_SECOND;
    }
}

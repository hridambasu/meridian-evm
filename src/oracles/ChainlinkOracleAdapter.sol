// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracle} from "../interfaces/IMeridian.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkOracleAdapter
/// @notice Combines a base/USD and (optional) quote/USD Chainlink-style feed into a
/// collateral/loan price scaled to 1e36 with token decimals folded in.
/// Reverts on stale or non-positive answers: for a lending market, a reverting
/// oracle (pausing borrows and liquidations) is safer than a wrong price.
contract ChainlinkOracleAdapter is IOracle {
    AggregatorV3Interface public immutable BASE_FEED;
    AggregatorV3Interface public immutable QUOTE_FEED; // address(0) => quote = 1
    uint256 public immutable MAX_STALENESS;
    uint256 public immutable SCALE_FACTOR;

    error StalePrice();
    error NegativePrice();

    constructor(
        AggregatorV3Interface baseFeed,
        AggregatorV3Interface quoteFeed,
        uint8 baseTokenDecimals,
        uint8 quoteTokenDecimals,
        uint256 maxStaleness
    ) {
        BASE_FEED = baseFeed;
        QUOTE_FEED = quoteFeed;
        MAX_STALENESS = maxStaleness;

        uint256 baseFeedDecimals = baseFeed.decimals();
        uint256 quoteFeedDecimals = address(quoteFeed) == address(0) ? 0 : quoteFeed.decimals();

        // price = baseAnswer / quoteAnswer * 10^(36 + quoteTokenDec + quoteFeedDec - baseTokenDec - baseFeedDec)
        SCALE_FACTOR = 10 ** (36 + quoteTokenDecimals + quoteFeedDecimals - baseTokenDecimals - baseFeedDecimals);
    }

    function price() external view returns (uint256) {
        uint256 base = _read(BASE_FEED);
        uint256 quote = address(QUOTE_FEED) == address(0) ? 1 : _read(QUOTE_FEED);
        return SCALE_FACTOR * base / quote;
    }

    function _read(AggregatorV3Interface feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert NegativePrice();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();
        return uint256(answer);
    }
}

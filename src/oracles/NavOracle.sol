// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracle} from "../interfaces/IMeridian.sol";

/// @title NavOracle
/// @notice Oracle for tokenized real-world assets (T-bill funds, private credit
/// tokens) whose price is a NAV published by the issuer / fund administrator,
/// not discovered on a DEX. Guardrails a lending market needs on top of a raw NAV:
///  - heartbeat: NAV older than `maxStaleness` makes the oracle revert,
///  - deviation bound: a single update cannot move NAV more than `maxDeviationBps`
///    (compromised updater key can't instantly reprice collateral 10x),
///  - optional haircut so the lending market prices collateral below NAV to
///    cover redemption delay / liquidity risk.
contract NavOracle is IOracle {
    uint256 public constant BPS = 10_000;

    address public owner;
    address public updater;
    uint256 public immutable SCALE_FACTOR; // turns 18-dec NAV into 1e36-scaled price
    uint256 public immutable MAX_STALENESS;
    uint256 public immutable MAX_DEVIATION_BPS;
    uint256 public haircutBps;

    uint256 public nav; // loan-token value of 1 whole RWA token, 18 decimals
    uint256 public updatedAt;

    event NavUpdated(uint256 nav, uint256 timestamp);
    event SetHaircut(uint256 haircutBps);
    event SetUpdater(address updater);

    error NotOwner();
    error NotUpdater();
    error StaleNav();
    error DeviationTooLarge();
    error InvalidHaircut();

    constructor(
        address _updater,
        uint256 initialNav,
        uint8 rwaTokenDecimals,
        uint8 loanTokenDecimals,
        uint256 maxStaleness,
        uint256 maxDeviationBps,
        uint256 _haircutBps
    ) {
        owner = msg.sender;
        updater = _updater;
        nav = initialNav;
        updatedAt = block.timestamp;
        MAX_STALENESS = maxStaleness;
        MAX_DEVIATION_BPS = maxDeviationBps;
        if (_haircutBps >= BPS) revert InvalidHaircut();
        haircutBps = _haircutBps;
        // price = nav(1e18) * 10^(36 + loanDec - rwaDec - 18)
        SCALE_FACTOR = 10 ** (18 + loanTokenDecimals - rwaTokenDecimals);
    }

    function setUpdater(address _updater) external {
        if (msg.sender != owner) revert NotOwner();
        updater = _updater;
        emit SetUpdater(_updater);
    }

    function setHaircut(uint256 _haircutBps) external {
        if (msg.sender != owner) revert NotOwner();
        if (_haircutBps >= BPS) revert InvalidHaircut();
        haircutBps = _haircutBps;
        emit SetHaircut(_haircutBps);
    }

    function updateNav(uint256 newNav) external {
        if (msg.sender != updater) revert NotUpdater();
        uint256 diff = newNav > nav ? newNav - nav : nav - newNav;
        if (diff * BPS > nav * MAX_DEVIATION_BPS) revert DeviationTooLarge();
        nav = newNav;
        updatedAt = block.timestamp;
        emit NavUpdated(newNav, block.timestamp);
    }

    function price() external view returns (uint256) {
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StaleNav();
        return nav * SCALE_FACTOR * (BPS - haircutBps) / BPS;
    }
}

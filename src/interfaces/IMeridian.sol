// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

type Id is bytes32;

/// @notice Immutable definition of one isolated market: one loan asset, one
/// collateral asset, one oracle, one rate model, one liquidation LTV.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

library MarketParamsLib {
    function id(MarketParams memory p) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(p)));
    }
}

/// @notice Price of 1 unit of collateral token quoted in loan token, scaled by 1e36
/// (already adjusted for the two tokens' decimals).
interface IOracle {
    function price() external view returns (uint256);
}

interface IIrm {
    /// @notice Per-second borrow rate (WAD). May update internal state; only called by Meridian.
    function borrowRate(MarketParams memory params, Market memory market) external returns (uint256);
    /// @notice Same as borrowRate but without mutating state.
    function borrowRateView(MarketParams memory params, Market memory market) external view returns (uint256);
}

interface IMeridianLiquidateCallback {
    function onMeridianLiquidate(uint256 repaidAssets, bytes calldata data) external;
}

interface IMeridianRepayCallback {
    function onMeridianRepay(uint256 assets, bytes calldata data) external;
}

interface IMeridianSupplyCallback {
    function onMeridianSupply(uint256 assets, bytes calldata data) external;
}

interface IMeridianSupplyCollateralCallback {
    function onMeridianSupplyCollateral(uint256 assets, bytes calldata data) external;
}

interface IMeridianFlashLoanCallback {
    function onMeridianFlashLoan(uint256 assets, bytes calldata data) external;
}

interface IMeridian {
    function owner() external view returns (address);
    function feeRecipient() external view returns (address);
    function isIrmEnabled(address irm) external view returns (bool);
    function isLltvEnabled(uint256 lltv) external view returns (bool);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    function position(Id id, address user) external view returns (uint256, uint128, uint128);
    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
    function idToMarketParams(Id id) external view returns (address, address, address, address, uint256);

    function createMarket(MarketParams memory params) external;
    function setAuthorization(address authorized, bool newIsAuthorized) external;

    function supply(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function withdraw(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function borrow(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function repay(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function supplyCollateral(MarketParams memory params, uint256 assets, address onBehalf, bytes memory data) external;
    function withdrawCollateral(MarketParams memory params, uint256 assets, address onBehalf, address receiver) external;
    function liquidate(
        MarketParams memory params,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
    function accrueInterest(MarketParams memory params) external;

    function expectedMarketBalances(MarketParams memory params)
        external
        view
        returns (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares);
    function expectedSupplyAssets(MarketParams memory params, address user) external view returns (uint256);
    function expectedBorrowAssets(MarketParams memory params, address user) external view returns (uint256);
    function healthFactor(MarketParams memory params, address user) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMeridian, MarketParams, IMeridianLiquidateCallback} from "../interfaces/IMeridian.sol";

/// @notice Minimal swap interface so the liquidator can route through any DEX
/// aggregator adapter (1inch / 0x / Uniswap / Curve) on mainnet.
interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address receiver)
        external
        returns (uint256 amountOut);
}

/// @title FlashLiquidator
/// @notice Capital-free liquidations: Meridian sends seized collateral first, then
/// calls back; we swap collateral -> loan token, approve the repayment and keep
/// the spread (the liquidation incentive minus swap slippage).
contract FlashLiquidator is IMeridianLiquidateCallback {
    using SafeERC20 for IERC20;

    IMeridian public immutable MERIDIAN;
    address public immutable OWNER;

    struct CallbackData {
        MarketParams params;
        ISwapper swapper;
        uint256 seizedAssets;
        uint256 minProfit;
    }

    error NotMeridian();
    error NotOwner();
    error InsufficientProfit(uint256 out, uint256 needed);

    event Liquidated(address indexed borrower, uint256 seized, uint256 repaid, uint256 profit);

    constructor(IMeridian meridian) {
        MERIDIAN = meridian;
        OWNER = msg.sender;
    }

    /// @param seizedAssets collateral to seize (computed off-chain by the keeper)
    /// @param minProfit revert unless profit in loan token >= minProfit (MEV / slippage guard)
    function liquidate(
        MarketParams calldata params,
        address borrower,
        uint256 seizedAssets,
        ISwapper swapper,
        uint256 minProfit
    ) external returns (uint256 profit) {
        if (msg.sender != OWNER) revert NotOwner();

        bytes memory data = abi.encode(CallbackData(params, swapper, seizedAssets, minProfit));
        (, uint256 repaid) = MERIDIAN.liquidate(params, borrower, seizedAssets, 0, data);

        profit = IERC20(params.loanToken).balanceOf(address(this));
        IERC20(params.loanToken).safeTransfer(OWNER, profit);
        emit Liquidated(borrower, seizedAssets, repaid, profit);
    }

    function onMeridianLiquidate(uint256 repaidAssets, bytes calldata data) external {
        if (msg.sender != address(MERIDIAN)) revert NotMeridian();
        CallbackData memory cb = abi.decode(data, (CallbackData));

        IERC20(cb.params.collateralToken).forceApprove(address(cb.swapper), cb.seizedAssets);
        uint256 out = cb.swapper.swap(
            cb.params.collateralToken, cb.params.loanToken, cb.seizedAssets, repaidAssets + cb.minProfit, address(this)
        );
        if (out < repaidAssets + cb.minProfit) revert InsufficientProfit(out, repaidAssets + cb.minProfit);

        IERC20(cb.params.loanToken).forceApprove(address(MERIDIAN), repaidAssets);
    }
}

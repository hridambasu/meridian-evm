// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    Id,
    MarketParams,
    Position,
    Market,
    MarketParamsLib,
    IOracle,
    IIrm,
    IMeridianLiquidateCallback,
    IMeridianRepayCallback,
    IMeridianSupplyCallback,
    IMeridianSupplyCollateralCallback,
    IMeridianFlashLoanCallback
} from "./interfaces/IMeridian.sol";
import {MathLib, SharesMathLib, WAD} from "./libraries/MathLib.sol";

/// @title Meridian
/// @notice Singleton, permissionless isolated lending markets.
/// Each market = (loanToken, collateralToken, oracle, irm, lltv). Risk is fully
/// contained per market: a bad oracle or collateral in one market cannot
/// create bad debt in another. Curator vaults sit on top to diversify.
contract Meridian {
    using MathLib for uint256;
    using MathLib for uint128;
    using SharesMathLib for uint256;
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    /* ------------------------------------------------------------------ */
    /*                              CONSTANTS                             */
    /* ------------------------------------------------------------------ */

    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant MAX_FEE = 0.25e18;
    /// @dev Liquidation incentive factor = min(MAX_LIF, 1 / (1 - CURSOR * (1 - lltv))).
    uint256 public constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 public constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;

    /* ------------------------------------------------------------------ */
    /*                               STORAGE                              */
    /* ------------------------------------------------------------------ */

    address public owner;
    address public feeRecipient;
    mapping(Id => mapping(address => Position)) public position;
    mapping(Id => Market) public market;
    mapping(Id => MarketParams) public idToMarketParams;
    mapping(address => bool) public isIrmEnabled;
    mapping(uint256 => bool) public isLltvEnabled;
    mapping(address => mapping(address => bool)) public isAuthorized;

    /* ------------------------------------------------------------------ */
    /*                                EVENTS                              */
    /* ------------------------------------------------------------------ */

    event SetOwner(address indexed newOwner);
    event SetFee(Id indexed id, uint256 newFee);
    event SetFeeRecipient(address indexed newFeeRecipient);
    event EnableIrm(address indexed irm);
    event EnableLltv(uint256 lltv);
    event CreateMarket(Id indexed id, MarketParams params);
    event Supply(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
    event Withdraw(
        Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares
    );
    event Borrow(
        Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares
    );
    event Repay(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
    event SupplyCollateral(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets);
    event WithdrawCollateral(
        Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets
    );
    event Liquidate(
        Id indexed id,
        address indexed caller,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets,
        uint256 badDebtAssets,
        uint256 badDebtShares
    );
    event FlashLoan(address indexed caller, address indexed token, uint256 assets);
    event SetAuthorization(address indexed authorizer, address indexed authorized, bool newIsAuthorized);
    event AccrueInterest(Id indexed id, uint256 prevBorrowRate, uint256 interest, uint256 feeShares);

    /* ------------------------------------------------------------------ */
    /*                                ERRORS                              */
    /* ------------------------------------------------------------------ */

    error NotOwner();
    error MarketNotCreated();
    error MarketAlreadyCreated();
    error IrmNotEnabled();
    error LltvNotEnabled();
    error MaxFeeExceeded();
    error InconsistentInput();
    error ZeroAssets();
    error ZeroAddress();
    error Unauthorized();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error HealthyPosition();
    error AlreadySet();

    constructor(address newOwner) {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit SetOwner(newOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /* ------------------------------------------------------------------ */
    /*                              GOVERNANCE                            */
    /* ------------------------------------------------------------------ */

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
        emit SetOwner(newOwner);
    }

    function enableIrm(address irm) external onlyOwner {
        if (isIrmEnabled[irm]) revert AlreadySet();
        isIrmEnabled[irm] = true;
        emit EnableIrm(irm);
    }

    function enableLltv(uint256 lltv) external onlyOwner {
        if (isLltvEnabled[lltv]) revert AlreadySet();
        require(lltv < WAD, "lltv >= 100%");
        isLltvEnabled[lltv] = true;
        emit EnableLltv(lltv);
    }

    function setFee(MarketParams memory params, uint256 newFee) external onlyOwner {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (newFee > MAX_FEE) revert MaxFeeExceeded();
        _accrueInterest(params, id); // fee must not apply retroactively
        market[id].fee = uint128(newFee);
        emit SetFee(id, newFee);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        feeRecipient = newFeeRecipient;
        emit SetFeeRecipient(newFeeRecipient);
    }

    /* ------------------------------------------------------------------ */
    /*                           MARKET CREATION                          */
    /* ------------------------------------------------------------------ */

    /// @notice Permissionless: anyone can create a market with a governance-approved
    /// IRM and LLTV. Oracle and assets are the creator's (and curators') choice.
    function createMarket(MarketParams memory params) external {
        Id id = params.id();
        if (!isIrmEnabled[params.irm]) revert IrmNotEnabled();
        if (!isLltvEnabled[params.lltv]) revert LltvNotEnabled();
        if (market[id].lastUpdate != 0) revert MarketAlreadyCreated();

        market[id].lastUpdate = uint128(block.timestamp);
        idToMarketParams[id] = params;
        emit CreateMarket(id, params);

        // Initialise IRM state for this market.
        if (params.irm != address(0)) IIrm(params.irm).borrowRate(params, market[id]);
    }

    /* ------------------------------------------------------------------ */
    /*                          SUPPLY / WITHDRAW                         */
    /* ------------------------------------------------------------------ */

    function supply(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256)
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (!_exactlyOneZero(assets, shares)) revert InconsistentInput();
        if (onBehalf == address(0)) revert ZeroAddress();

        _accrueInterest(params, id);
        Market storage m = market[id];

        if (assets > 0) shares = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsUp(m.totalSupplyAssets, m.totalSupplyShares);

        position[id][onBehalf].supplyShares += shares;
        m.totalSupplyShares = (m.totalSupplyShares + shares).toUint128();
        m.totalSupplyAssets = (m.totalSupplyAssets + assets).toUint128();

        emit Supply(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMeridianSupplyCallback(msg.sender).onMeridianSupply(assets, data);
        IERC20(params.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    function withdraw(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (!_exactlyOneZero(assets, shares)) revert InconsistentInput();
        if (receiver == address(0)) revert ZeroAddress();
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();

        _accrueInterest(params, id);
        Market storage m = market[id];

        if (assets > 0) shares = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);

        position[id][onBehalf].supplyShares -= shares;
        m.totalSupplyShares -= shares.toUint128();
        m.totalSupplyAssets -= assets.toUint128();

        if (m.totalBorrowAssets > m.totalSupplyAssets) revert InsufficientLiquidity();

        emit Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);
        IERC20(params.loanToken).safeTransfer(receiver, assets);
        return (assets, shares);
    }

    /* ------------------------------------------------------------------ */
    /*                            BORROW / REPAY                          */
    /* ------------------------------------------------------------------ */

    function borrow(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (!_exactlyOneZero(assets, shares)) revert InconsistentInput();
        if (receiver == address(0)) revert ZeroAddress();
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();

        _accrueInterest(params, id);
        Market storage m = market[id];

        if (assets > 0) shares = assets.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        else assets = shares.toAssetsDown(m.totalBorrowAssets, m.totalBorrowShares);

        position[id][onBehalf].borrowShares += shares.toUint128();
        m.totalBorrowShares = (m.totalBorrowShares + shares).toUint128();
        m.totalBorrowAssets = (m.totalBorrowAssets + assets).toUint128();

        if (!_isHealthy(params, id, onBehalf)) revert InsufficientCollateral();
        if (m.totalBorrowAssets > m.totalSupplyAssets) revert InsufficientLiquidity();

        emit Borrow(id, msg.sender, onBehalf, receiver, assets, shares);
        IERC20(params.loanToken).safeTransfer(receiver, assets);
        return (assets, shares);
    }

    function repay(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256)
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (!_exactlyOneZero(assets, shares)) revert InconsistentInput();
        if (onBehalf == address(0)) revert ZeroAddress();

        _accrueInterest(params, id);
        Market storage m = market[id];

        if (assets > 0) shares = assets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
        else assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        position[id][onBehalf].borrowShares -= shares.toUint128();
        m.totalBorrowShares -= shares.toUint128();
        // Rounding up on repay can exceed total by 1 wei; floor at zero.
        m.totalBorrowAssets = uint256(m.totalBorrowAssets).zeroFloorSub(assets).toUint128();

        emit Repay(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMeridianRepayCallback(msg.sender).onMeridianRepay(assets, data);
        IERC20(params.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    /* ------------------------------------------------------------------ */
    /*                              COLLATERAL                            */
    /* ------------------------------------------------------------------ */

    /// @dev No interest accrual needed: collateral does not earn interest.
    function supplyCollateral(MarketParams memory params, uint256 assets, address onBehalf, bytes calldata data)
        external
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (assets == 0) revert ZeroAssets();
        if (onBehalf == address(0)) revert ZeroAddress();

        position[id][onBehalf].collateral += assets.toUint128();
        emit SupplyCollateral(id, msg.sender, onBehalf, assets);

        if (data.length > 0) {
            IMeridianSupplyCollateralCallback(msg.sender).onMeridianSupplyCollateral(assets, data);
        }
        IERC20(params.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MarketParams memory params, uint256 assets, address onBehalf, address receiver)
        external
    {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (assets == 0) revert ZeroAssets();
        if (receiver == address(0)) revert ZeroAddress();
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();

        _accrueInterest(params, id);
        position[id][onBehalf].collateral -= assets.toUint128();
        if (!_isHealthy(params, id, onBehalf)) revert InsufficientCollateral();

        emit WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);
        IERC20(params.collateralToken).safeTransfer(receiver, assets);
    }

    /* ------------------------------------------------------------------ */
    /*                              LIQUIDATION                           */
    /* ------------------------------------------------------------------ */

    /// @notice Liquidate an unhealthy position. Specify either the collateral to
    /// seize or the debt shares to repay. Liquidator receives collateral first and
    /// may repay inside the callback (flash liquidation, no upfront capital).
    /// If the borrower's collateral reaches zero with debt outstanding, the
    /// remainder is realised as bad debt and socialised across that market's
    /// suppliers only.
    function liquidate(
        MarketParams memory params,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        if (!_exactlyOneZero(seizedAssets, repaidShares)) revert InconsistentInput();

        _accrueInterest(params, id);
        Market storage m = market[id];

        uint256 collateralPrice = IOracle(params.oracle).price();
        if (_isHealthy(params, id, borrower, collateralPrice)) revert HealthyPosition();

        uint256 lif = liquidationIncentiveFactor(params.lltv);

        if (seizedAssets > 0) {
            uint256 seizedQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);
            repaidShares = seizedQuoted.wDivUp(lif).toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            seizedAssets = repaidShares.toAssetsDown(m.totalBorrowAssets, m.totalBorrowShares).wMulDown(lif).mulDivDown(
                ORACLE_PRICE_SCALE, collateralPrice
            );
        }
        uint256 repaidAssets = repaidShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        Position storage pos = position[id][borrower];
        pos.borrowShares -= repaidShares.toUint128();
        m.totalBorrowShares -= repaidShares.toUint128();
        m.totalBorrowAssets = uint256(m.totalBorrowAssets).zeroFloorSub(repaidAssets).toUint128();
        pos.collateral -= seizedAssets.toUint128();

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (pos.collateral == 0 && pos.borrowShares > 0) {
            badDebtShares = pos.borrowShares;
            badDebtAssets = MathLib.min(
                m.totalBorrowAssets, badDebtShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares)
            );
            m.totalBorrowAssets -= badDebtAssets.toUint128();
            m.totalSupplyAssets -= badDebtAssets.toUint128();
            m.totalBorrowShares -= badDebtShares.toUint128();
            pos.borrowShares = 0;
        }

        emit Liquidate(id, msg.sender, borrower, repaidAssets, repaidShares, seizedAssets, badDebtAssets, badDebtShares);

        IERC20(params.collateralToken).safeTransfer(msg.sender, seizedAssets);
        if (data.length > 0) IMeridianLiquidateCallback(msg.sender).onMeridianLiquidate(repaidAssets, data);
        IERC20(params.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }

    function liquidationIncentiveFactor(uint256 lltv) public pure returns (uint256) {
        return MathLib.min(
            MAX_LIQUIDATION_INCENTIVE_FACTOR, WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - lltv))
        );
    }

    /* ------------------------------------------------------------------ */
    /*                              FLASH LOANS                           */
    /* ------------------------------------------------------------------ */

    /// @notice Free flash loans of any token held by the contract (all markets' liquidity).
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        if (assets == 0) revert ZeroAssets();
        emit FlashLoan(msg.sender, token, assets);
        IERC20(token).safeTransfer(msg.sender, assets);
        IMeridianFlashLoanCallback(msg.sender).onMeridianFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* ------------------------------------------------------------------ */
    /*                             AUTHORIZATION                          */
    /* ------------------------------------------------------------------ */

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
        emit SetAuthorization(msg.sender, authorized, newIsAuthorized);
    }

    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* ------------------------------------------------------------------ */
    /*                           INTEREST ACCRUAL                         */
    /* ------------------------------------------------------------------ */

    function accrueInterest(MarketParams memory params) external {
        Id id = params.id();
        if (market[id].lastUpdate == 0) revert MarketNotCreated();
        _accrueInterest(params, id);
    }

    function _accrueInterest(MarketParams memory params, Id id) internal {
        Market storage m = market[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;

        if (params.irm != address(0)) {
            uint256 rate = IIrm(params.irm).borrowRate(params, m);
            uint256 interest = uint256(m.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(elapsed));
            m.totalBorrowAssets = (m.totalBorrowAssets + interest).toUint128();
            m.totalSupplyAssets = (m.totalSupplyAssets + interest).toUint128();

            uint256 feeShares;
            if (m.fee != 0) {
                uint256 feeAmount = interest.wMulDown(m.fee);
                // Shares minted such that fee recipient owns `feeAmount` of the post-interest supply.
                feeShares = feeAmount.toSharesDown(m.totalSupplyAssets - feeAmount, m.totalSupplyShares);
                position[id][feeRecipient].supplyShares += feeShares;
                m.totalSupplyShares = (m.totalSupplyShares + feeShares).toUint128();
            }
            emit AccrueInterest(id, rate, interest, feeShares);
        }
        m.lastUpdate = uint128(block.timestamp);
    }

    /* ------------------------------------------------------------------ */
    /*                                HEALTH                              */
    /* ------------------------------------------------------------------ */

    function _isHealthy(MarketParams memory params, Id id, address borrower) internal view returns (bool) {
        if (position[id][borrower].borrowShares == 0) return true;
        return _isHealthy(params, id, borrower, IOracle(params.oracle).price());
    }

    function _isHealthy(MarketParams memory params, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        returns (bool)
    {
        Position storage pos = position[id][borrower];
        Market storage m = market[id];
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 maxBorrow =
            uint256(pos.collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(params.lltv);
        return maxBorrow >= borrowed;
    }

    /* ------------------------------------------------------------------ */
    /*                       VIEW HELPERS (FOR VAULTS / UI)               */
    /* ------------------------------------------------------------------ */

    /// @notice Market balances as they would be after accruing interest now.
    function expectedMarketBalances(MarketParams memory params)
        public
        view
        returns (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares)
    {
        Id id = params.id();
        Market memory m = market[id];
        totalSupplyAssets = m.totalSupplyAssets;
        totalSupplyShares = m.totalSupplyShares;
        totalBorrowAssets = m.totalBorrowAssets;
        totalBorrowShares = m.totalBorrowShares;

        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed != 0 && totalBorrowAssets != 0 && params.irm != address(0)) {
            uint256 rate = IIrm(params.irm).borrowRateView(params, m);
            uint256 interest = totalBorrowAssets.wMulDown(rate.wTaylorCompounded(elapsed));
            totalBorrowAssets += interest;
            totalSupplyAssets += interest;
            if (m.fee != 0) {
                uint256 feeAmount = interest.wMulDown(m.fee);
                totalSupplyShares += feeAmount.toSharesDown(totalSupplyAssets - feeAmount, totalSupplyShares);
            }
        }
    }

    function expectedSupplyAssets(MarketParams memory params, address user) external view returns (uint256) {
        (uint256 tsa, uint256 tss,,) = expectedMarketBalances(params);
        return position[params.id()][user].supplyShares.toAssetsDown(tsa, tss);
    }

    function expectedBorrowAssets(MarketParams memory params, address user) public view returns (uint256) {
        (,, uint256 tba, uint256 tbs) = expectedMarketBalances(params);
        return uint256(position[params.id()][user].borrowShares).toAssetsUp(tba, tbs);
    }

    /// @notice Health factor in WAD. >= 1e18 is healthy; type(uint256).max if no debt.
    function healthFactor(MarketParams memory params, address user) external view returns (uint256) {
        uint256 debt = expectedBorrowAssets(params, user);
        if (debt == 0) return type(uint256).max;
        uint256 collateral = position[params.id()][user].collateral;
        uint256 maxBorrow =
            collateral.mulDivDown(IOracle(params.oracle).price(), ORACLE_PRICE_SCALE).wMulDown(params.lltv);
        return maxBorrow.wDivDown(debt);
    }

    function _exactlyOneZero(uint256 x, uint256 y) internal pure returns (bool) {
        return (x == 0) != (y == 0);
    }
}

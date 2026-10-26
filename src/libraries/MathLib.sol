// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

uint256 constant WAD = 1e18;

/// @title MathLib
/// @notice Fixed-point helpers. All "w" functions operate on 18-decimal WAD numbers.
library MathLib {
    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    /// @dev Third-order Taylor approximation of e^(x*n) - 1, used to continuously
    /// compound a per-second rate x over n seconds. Underestimates slightly, which
    /// is the conservative direction for lenders' accounting of borrower debt.
    function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }

    function zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : 0;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    function toUint128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "uint128 overflow");
        return uint128(x);
    }
}

/// @title SharesMathLib
/// @notice Asset <-> share conversions with virtual shares/assets. The virtual
/// offset makes the first-depositor share-inflation attack uneconomical.
library SharesMathLib {
    using MathLib for uint256;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivDown(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivDown(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivUp(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivUp(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}

/// @title ExpLib
/// @notice Signed WAD exponential, accurate to ~3e-6 relative error on the range
/// used by the adaptive IRM. Uses range reduction e^x = 2^q * e^r with |r| <= ln2/2.
library ExpLib {
    int256 internal constant LN_2_INT = 0.693147180559945309e18;
    /// @dev Below this, e^x rounds to 0 in WAD.
    int256 internal constant LN_WEI_INT = -41.446531673892822312e18;
    /// @dev Above this the result exceeds anything the IRM can use; we saturate.
    int256 internal constant WEXP_UPPER_BOUND = 46e18;
    int256 internal constant WEXP_UPPER_VALUE = type(int128).max;

    function wExp(int256 x) internal pure returns (int256) {
        unchecked {
            if (x < LN_WEI_INT) return 0;
            if (x >= WEXP_UPPER_BOUND) return WEXP_UPPER_VALUE;

            // q = round(x / ln2), r = x - q*ln2
            int256 roundingAdjustment = (x < 0) ? -(LN_2_INT / 2) : (LN_2_INT / 2);
            int256 q = (x + roundingAdjustment) / LN_2_INT;
            int256 r = x - q * LN_2_INT;

            // e^r ~= 1 + r + r^2/2 + r^3/6 + r^4/24 + r^5/120  (|r| <= 0.347 => rel. err < 3e-6)
            int256 r2 = (r * r) / 1e18;
            int256 r3 = (r2 * r) / 1e18;
            int256 r4 = (r3 * r) / 1e18;
            int256 r5 = (r4 * r) / 1e18;
            int256 expR = 1e18 + r + r2 / 2 + r3 / 6 + r4 / 24 + r5 / 120;

            if (q >= 0) return expR << uint256(q);
            return expR >> uint256(-q);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {Meridian} from "../../src/Meridian.sol";
import {MockERC20, MockOracle} from "../../src/mocks/Mocks.sol";
import {MarketParams, Id} from "../../src/interfaces/IMeridian.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Drives random sequences of actions against one market.
contract Handler is CommonBase, StdCheats, StdUtils {
    Meridian internal meridian;
    MarketParams internal params;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockOracle internal oracle;

    address[] public actors;

    constructor(Meridian _m, MarketParams memory _p, MockERC20 _usdc, MockERC20 _weth, MockOracle _oracle) {
        meridian = _m;
        params = _p;
        usdc = _usdc;
        weth = _weth;
        oracle = _oracle;
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0x1000 + i));
            actors.push(a);
            vm.startPrank(a);
            usdc.approve(address(meridian), type(uint256).max);
            weth.approve(address(meridian), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function supply(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1, 1e12);
        usdc.mint(a, amt);
        vm.prank(a);
        meridian.supply(params, amt, 0, a, "");
    }

    function withdraw(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        uint256 max = meridian.expectedSupplyAssets(params, a);
        if (max == 0) return;
        amt = bound(amt, 1, max);
        vm.prank(a);
        meridian.withdraw(params, amt, 0, a, a);
    }

    function supplyCollateral(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1e9, 100 ether);
        weth.mint(a, amt);
        vm.prank(a);
        meridian.supplyCollateral(params, amt, a, "");
    }

    function borrow(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1, 1e11);
        vm.prank(a);
        meridian.borrow(params, amt, 0, a, a);
    }

    function repay(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        uint256 debt = meridian.expectedBorrowAssets(params, a);
        if (debt == 0) return;
        amt = bound(amt, 1, debt);
        usdc.mint(a, amt);
        vm.prank(a);
        meridian.repay(params, amt, 0, a, "");
    }

    function movePrice(uint256 newPrice) external {
        oracle.setPrice(bound(newPrice, 500e24, 6_000e24));
    }

    function liquidate(uint256 seed, uint256 liqSeed, uint256 seize) external {
        address borrower = _actor(seed);
        address liq = _actor(liqSeed);
        (,, uint128 col) = meridian.position(_id(), borrower);
        if (col == 0) return;
        seize = bound(seize, 1, col);
        usdc.mint(liq, 1e15);
        vm.prank(liq);
        meridian.liquidate(params, borrower, seize, 0, "");
    }

    function warp(uint256 dt) external {
        skip(bound(dt, 1, 30 days));
    }

    function _id() internal view returns (Id) {
        return Id.wrap(keccak256(abi.encode(params)));
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}

contract MeridianInvariantTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(meridian, params, usdc, weth, oracle);
        targetContract(address(handler));
    }

    /// Borrowed assets can never exceed supplied assets (no phantom liquidity).
    function invariant_borrowLeSupply() public view {
        (uint256 tsa,, uint256 tba,,,) = _market();
        assertLe(tba, tsa);
    }

    /// The contract always holds enough tokens to honour every supplier's claim on idle liquidity
    /// and every collateral position.
    function invariant_solvency() public view {
        (uint256 tsa,, uint256 tba,,,) = _market();
        assertGe(usdc.balanceOf(address(meridian)), tsa - tba);

        uint256 totalCollateral;
        for (uint256 i; i < handler.actorsLength(); ++i) {
            (,, uint128 c) = meridian.position(id, handler.actors(i));
            totalCollateral += c;
        }
        assertEq(weth.balanceOf(address(meridian)), totalCollateral);
    }

    /// Sum of user borrow shares equals total borrow shares.
    function invariant_borrowSharesConsistent() public view {
        (,,, uint256 tbs,,) = _market();
        uint256 sum;
        for (uint256 i; i < handler.actorsLength(); ++i) {
            (, uint128 b,) = meridian.position(id, handler.actors(i));
            sum += b;
        }
        assertEq(sum, tbs);
    }

    /// Sum of supply shares (actors + fee recipient) equals total supply shares.
    function invariant_supplySharesConsistent() public view {
        (, uint256 tss,,,,) = _market();
        uint256 sum;
        for (uint256 i; i < handler.actorsLength(); ++i) {
            (uint256 s,,) = meridian.position(id, handler.actors(i));
            sum += s;
        }
        (uint256 fs,,) = meridian.position(id, FEE_RECIPIENT);
        assertEq(sum + fs, tss);
    }
}

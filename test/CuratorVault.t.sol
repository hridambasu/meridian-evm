// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {CuratorVault, MarketAllocation} from "../src/vault/CuratorVault.sol";
import {MockERC20, MockOracle} from "../src/mocks/Mocks.sol";
import {MarketParams, MarketParamsLib, Id, IMeridian} from "../src/interfaces/IMeridian.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CuratorVaultTest is BaseTest {
    using MarketParamsLib for MarketParams;

    uint256 internal constant TIMELOCK = 1 days;

    CuratorVault internal vault;
    MockERC20 internal wbtc;
    MarketParams internal btcParams;
    Id internal btcId;

    address internal CURATOR = makeAddr("curator");
    address internal ALLOCATOR = makeAddr("allocator");
    address internal GUARDIAN = makeAddr("guardian");
    address internal DEPOSITOR = makeAddr("depositor");
    address internal VAULT_FEE = makeAddr("vaultFee");

    function setUp() public override {
        super.setUp();

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        // 1 WBTC (8 dec) = 60k USDC (6 dec)
        MockOracle btcOracle = new MockOracle(60_000 * 1e6 * 1e36 / 1e8);
        btcParams = MarketParams(address(usdc), address(wbtc), address(btcOracle), address(irm), LLTV);
        btcId = btcParams.id();
        meridian.createMarket(btcParams);

        vault = new CuratorVault(OWNER, IMeridian(address(meridian)), TIMELOCK, IERC20(address(usdc)), "Meridian USDC Prime", "mUSDC");
        vm.startPrank(OWNER);
        vault.setCurator(CURATOR);
        vault.setIsAllocator(ALLOCATOR, true);
        vault.setGuardian(GUARDIAN);
        vault.setFeeRecipient(VAULT_FEE);
        vault.setFee(0.1e18);
        vm.stopPrank();

        _enableMarket(params, 1_000_000e6);
        _enableMarket(btcParams, 500_000e6);

        Id[] memory queue = new Id[](2);
        queue[0] = id;
        queue[1] = btcId;
        vm.prank(ALLOCATOR);
        vault.setSupplyQueue(queue);

        vm.prank(DEPOSITOR);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _enableMarket(MarketParams memory p, uint256 cap) internal {
        vm.prank(CURATOR);
        vault.submitCap(p, cap);
        skip(TIMELOCK);
        vault.acceptCap(p);
    }

    function _deposit(uint256 assets) internal returns (uint256 shares) {
        usdc.mint(DEPOSITOR, assets);
        vm.prank(DEPOSITOR);
        shares = vault.deposit(assets, DEPOSITOR);
    }

    /* -------------------------------- caps ---------------------------------- */

    function test_capIncrease_isTimelocked() public {
        vm.prank(CURATOR);
        vault.submitCap(params, 2_000_000e6);
        vm.expectRevert(CuratorVault.TimelockNotElapsed.selector);
        vault.acceptCap(params);

        skip(TIMELOCK);
        vault.acceptCap(params);
        (uint184 cap,) = vault.config(id);
        assertEq(cap, 2_000_000e6);
    }

    function test_capDecrease_isInstant() public {
        vm.prank(CURATOR);
        vault.submitCap(params, 1e6);
        (uint184 cap,) = vault.config(id);
        assertEq(cap, 1e6);
    }

    function test_guardianCanVetoPendingCap() public {
        vm.prank(CURATOR);
        vault.submitCap(params, 5_000_000e6);
        vm.prank(GUARDIAN);
        vault.revokePendingCap(id);
        skip(TIMELOCK);
        vm.expectRevert(CuratorVault.NoPendingValue.selector);
        vault.acceptCap(params);
    }

    function test_onlyCuratorCanSubmitCap() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(CuratorVault.NotCuratorRole.selector);
        vault.submitCap(params, 1);
    }

    function test_cannotAddMarketWithWrongAsset() public {
        MarketParams memory bad = params;
        bad.loanToken = address(weth);
        vm.prank(CURATOR);
        vm.expectRevert(CuratorVault.InconsistentAsset.selector);
        vault.submitCap(bad, 1);
    }

    function test_timelockDecrease_isTimelocked() public {
        vm.prank(OWNER);
        vault.submitTimelock(3 days); // increase: instant
        assertEq(vault.timelock(), 3 days);

        vm.prank(OWNER);
        vault.submitTimelock(1 days); // decrease: pending
        assertEq(vault.timelock(), 3 days);
        skip(3 days);
        vault.acceptTimelock();
        assertEq(vault.timelock(), 1 days);
    }

    /* ---------------------------- deposit/withdraw -------------------------- */

    function test_deposit_fillsSupplyQueueInOrder() public {
        _deposit(1_200_000e6);
        assertEq(meridian.expectedSupplyAssets(params, address(vault)), 1_000_000e6);
        assertEq(meridian.expectedSupplyAssets(btcParams, address(vault)), 200_000e6);
        assertEq(vault.totalAssets(), 1_200_000e6);
    }

    function test_deposit_overflowStaysIdle() public {
        _deposit(2_000_000e6);
        assertEq(usdc.balanceOf(address(vault)), 500_000e6);
        assertEq(vault.totalAssets(), 2_000_000e6);
    }

    function test_withdraw_pullsAcrossMarkets() public {
        _deposit(1_200_000e6);
        vm.prank(DEPOSITOR);
        vault.withdraw(1_100_000e6, DEPOSITOR, DEPOSITOR);
        assertEq(usdc.balanceOf(DEPOSITOR), 1_100_000e6);
        assertApproxEqAbs(vault.totalAssets(), 100_000e6, 1);
    }

    function test_maxWithdraw_respectsBorrowedLiquidity() public {
        _deposit(1_000_000e6);
        _depositCollateral(BORROWER, 1_000 ether);
        _borrow(BORROWER, 900_000e6);

        assertApproxEqAbs(vault.maxWithdraw(DEPOSITOR), 100_000e6, 1);
        vm.prank(DEPOSITOR);
        vm.expectRevert();
        vault.withdraw(200_000e6, DEPOSITOR, DEPOSITOR);
    }

    function test_yieldAccrues_andFeeIsTaken() public {
        uint256 shares = _deposit(1_000_000e6);
        _depositCollateral(BORROWER, 1_000 ether);
        _borrow(BORROWER, 900_000e6);

        skip(365 days);
        uint256 assetsAfter = vault.previewRedeem(shares);
        // Rate-at-target drifted down while the market sat idle during the cap timelock,
        // so net yield lands at ~2.5% rather than 4% * 90% * 90%.
        assertGt(assetsAfter, 1_020_000e6, "depositor earned yield net of fee");

        // trigger fee accrual
        _deposit(1e6);
        uint256 feeAssets = vault.previewRedeem(vault.balanceOf(VAULT_FEE));
        uint256 gross = vault.totalAssets() - 1_000_000e6 - 1e6;
        assertApproxEqRel(feeAssets, gross / 10, 0.01e18);
    }

    function test_inflationAttack_isUnprofitable() public {
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 10_001e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker);
        usdc.transfer(address(vault), 10_000e6); // donation
        vm.stopPrank();

        uint256 victimShares = _deposit(1_000e6);
        assertGt(victimShares, 0, "victim gets shares");
        uint256 victimAssets = vault.previewRedeem(victimShares);
        assertApproxEqRel(victimAssets, 1_000e6, 0.001e18);
    }

    /* ------------------------------ reallocation ---------------------------- */

    function test_reallocate_movesLiquidity() public {
        _deposit(1_000_000e6);

        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation(params, 600_000e6);
        allocs[1] = MarketAllocation(btcParams, type(uint256).max);
        vm.prank(ALLOCATOR);
        vault.reallocate(allocs);

        assertEq(meridian.expectedSupplyAssets(params, address(vault)), 600_000e6);
        assertEq(meridian.expectedSupplyAssets(btcParams, address(vault)), 400_000e6);
    }

    function test_reallocate_respectsCap() public {
        _deposit(1_000_000e6);
        MarketAllocation[] memory allocs = new MarketAllocation[](2);
        allocs[0] = MarketAllocation(params, 0);
        allocs[1] = MarketAllocation(btcParams, type(uint256).max);
        vm.prank(ALLOCATOR);
        vm.expectRevert(abi.encodeWithSelector(CuratorVault.SupplyCapExceeded.selector, btcId));
        vault.reallocate(allocs);
    }

    function test_reallocate_onlyAllocator() public {
        MarketAllocation[] memory allocs = new MarketAllocation[](0);
        vm.prank(DEPOSITOR);
        vm.expectRevert(CuratorVault.NotAllocatorRole.selector);
        vault.reallocate(allocs);
    }

    /* ----------------------------- market removal --------------------------- */

    function test_removeMarket_requiresZeroCapAndSupply() public {
        _deposit(1_200_000e6);
        uint256[] memory keepFirst = new uint256[](1);
        keepFirst[0] = 0;

        // cap still set
        vm.prank(ALLOCATOR);
        vm.expectRevert(abi.encodeWithSelector(CuratorVault.InvalidMarketRemoval.selector, btcId));
        vault.updateWithdrawQueue(keepFirst);

        // zero cap but still has supply
        vm.prank(CURATOR);
        vault.submitCap(btcParams, 0);
        vm.prank(ALLOCATOR);
        vm.expectRevert(abi.encodeWithSelector(CuratorVault.InvalidMarketRemoval.selector, btcId));
        vault.updateWithdrawQueue(keepFirst);

        // move funds to idle, then remove
        MarketAllocation[] memory allocs = new MarketAllocation[](1);
        allocs[0] = MarketAllocation(btcParams, 0);
        vm.prank(ALLOCATOR);
        vault.reallocate(allocs);
        vm.prank(ALLOCATOR);
        vault.updateWithdrawQueue(keepFirst);
        assertEq(vault.withdrawQueueLength(), 1);
        assertApproxEqAbs(vault.totalAssets(), 1_200_000e6, 1);
    }

    /* ---------------------------- isolation property ------------------------ */

    function test_badDebtInOneMarket_isContained() public {
        _deposit(1_200_000e6); // 1M in WETH market, 200k in BTC market

        // Some other lender also supplies to the BTC market; a BTC borrower goes underwater.
        _depositCollateralBtc(BORROWER, 5e8); // $300k
        vm.prank(BORROWER);
        meridian.borrow(btcParams, 200_000e6, 0, BORROWER, BORROWER);

        MockOracle(btcParams.oracle).setPrice(20_000 * 1e6 * 1e36 / 1e8); // BTC -66%
        usdc.mint(LIQUIDATOR, 1_000_000e6);
        vm.prank(LIQUIDATOR);
        meridian.liquidate(btcParams, BORROWER, 5e8, 0, "");

        // WETH market untouched
        assertEq(meridian.expectedSupplyAssets(params, address(vault)), 1_000_000e6);
        // Vault loses only part of its 200k BTC sleeve
        assertLt(vault.totalAssets(), 1_200_000e6);
        assertGt(vault.totalAssets(), 1_000_000e6);
    }

    function _depositCollateralBtc(address who, uint256 amt) internal {
        wbtc.mint(who, amt);
        vm.startPrank(who);
        wbtc.approve(address(meridian), amt);
        meridian.supplyCollateral(btcParams, amt, who, "");
        vm.stopPrank();
    }
}

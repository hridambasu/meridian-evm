// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Meridian} from "../src/Meridian.sol";
import {AdaptiveCurveIrm} from "../src/irm/AdaptiveCurveIrm.sol";
import {FixedRateIrm} from "../src/irm/FixedRateIrm.sol";
import {NavOracle} from "../src/oracles/NavOracle.sol";
import {CuratorVault} from "../src/vault/CuratorVault.sol";
import {FlashLiquidator} from "../src/periphery/FlashLiquidator.sol";
import {MockERC20, MockOracle, MockSwapper} from "../src/mocks/Mocks.sol";
import {MarketParams, IMeridian} from "../src/interfaces/IMeridian.sol";

/// @notice Step 1 of the local demo: deploy protocol, tokens, oracles, three
/// markets (crypto-collateral + RWA fixed-rate) and a curator vault; submit caps.
/// Caps are timelocked, so `Seed.s.sol` accepts them after time is advanced.
///
///   anvil &
///   forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
contract Deploy is Script {
    uint256 constant LLTV_CRYPTO = 0.86e18;
    uint256 constant LLTV_RWA = 0.915e18;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        Meridian meridian = new Meridian(deployer);
        AdaptiveCurveIrm irm = new AdaptiveCurveIrm(address(meridian));
        FixedRateIrm fixed5 = new FixedRateIrm(0.05e18);

        meridian.enableIrm(address(irm));
        meridian.enableIrm(address(fixed5));
        meridian.enableLltv(LLTV_CRYPTO);
        meridian.enableLltv(LLTV_RWA);
        meridian.setFeeRecipient(deployer);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockERC20 tbill = new MockERC20("Tokenized T-Bill Fund", "tBILL", 6);

        MockOracle ethOracle = new MockOracle(3_000e24);
        MockOracle btcOracle = new MockOracle(60_000 * 1e6 * 1e36 / 1e8);
        // NAV 1.02, 1% max move per update, 1% haircut, 3-day heartbeat
        NavOracle tbillOracle = new NavOracle(deployer, 1.02e18, 6, 6, 3 days, 100, 100);

        MarketParams memory ethMkt = MarketParams(address(usdc), address(weth), address(ethOracle), address(irm), LLTV_CRYPTO);
        MarketParams memory btcMkt = MarketParams(address(usdc), address(wbtc), address(btcOracle), address(irm), LLTV_CRYPTO);
        MarketParams memory rwaMkt = MarketParams(address(usdc), address(tbill), address(tbillOracle), address(fixed5), LLTV_RWA);
        meridian.createMarket(ethMkt);
        meridian.createMarket(btcMkt);
        meridian.createMarket(rwaMkt);
        meridian.setFee(ethMkt, 0.05e18);
        meridian.setFee(btcMkt, 0.05e18);

        CuratorVault vault = new CuratorVault(
            deployer, IMeridian(address(meridian)), 1 days, IERC20(address(usdc)), "Meridian USDC Prime", "mpUSDC"
        );
        vault.setCurator(deployer);
        vault.setIsAllocator(deployer, true);
        vault.setFeeRecipient(deployer);
        vault.setFee(0.1e18);
        vault.submitCap(ethMkt, 2_000_000e6);
        vault.submitCap(btcMkt, 1_500_000e6);
        vault.submitCap(rwaMkt, 1_000_000e6);

        FlashLiquidator liquidator = new FlashLiquidator(IMeridian(address(meridian)));
        MockSwapper ethSwapper = new MockSwapper(ethOracle, 30);
        MockSwapper btcSwapper = new MockSwapper(btcOracle, 30);
        MockSwapper rwaSwapper = new MockSwapper(tbillOracle, 20);

        vm.stopBroadcast();

        string memory o = "deployment";
        vm.serializeAddress(o, "meridian", address(meridian));
        vm.serializeAddress(o, "adaptiveIrm", address(irm));
        vm.serializeAddress(o, "fixedIrm5", address(fixed5));
        vm.serializeAddress(o, "usdc", address(usdc));
        vm.serializeAddress(o, "weth", address(weth));
        vm.serializeAddress(o, "wbtc", address(wbtc));
        vm.serializeAddress(o, "tbill", address(tbill));
        vm.serializeAddress(o, "ethOracle", address(ethOracle));
        vm.serializeAddress(o, "btcOracle", address(btcOracle));
        vm.serializeAddress(o, "tbillOracle", address(tbillOracle));
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "flashLiquidator", address(liquidator));
        vm.serializeAddress(o, "ethSwapper", address(ethSwapper));
        vm.serializeAddress(o, "btcSwapper", address(btcSwapper));
        string memory json = vm.serializeAddress(o, "rwaSwapper", address(rwaSwapper));
        vm.writeJson(json, "./deployments/local.json");

        console2.log("Meridian       ", address(meridian));
        console2.log("CuratorVault   ", address(vault));
        console2.log("FlashLiquidator", address(liquidator));
    }
}

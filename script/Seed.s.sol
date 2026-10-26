// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Meridian} from "../src/Meridian.sol";
import {CuratorVault} from "../src/vault/CuratorVault.sol";
import {MockERC20} from "../src/mocks/Mocks.sol";
import {MarketParams, Id, MarketParamsLib} from "../src/interfaces/IMeridian.sol";

/// @notice Step 2 (run after advancing anvil time past the 1-day timelock):
/// accept caps, set the supply queue, deposit into the vault and open a few
/// borrower positions at different health factors so the keeper has work.
///
///   cast rpc evm_increaseTime 86401 && cast rpc evm_mine
///   forge script script/Seed.s.sol --rpc-url http://localhost:8545 --broadcast
contract Seed is Script {
    using stdJson for string;
    using MarketParamsLib for MarketParams;

    // Anvil default accounts 0..3
    uint256 constant PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant PK1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant PK2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant PK3 = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    function run() external {
        string memory json = vm.readFile("./deployments/local.json");
        Meridian meridian = Meridian(json.readAddress(".meridian"));
        CuratorVault vault = CuratorVault(json.readAddress(".vault"));
        MockERC20 usdc = MockERC20(json.readAddress(".usdc"));
        MockERC20 weth = MockERC20(json.readAddress(".weth"));
        MockERC20 wbtc = MockERC20(json.readAddress(".wbtc"));
        MockERC20 tbill = MockERC20(json.readAddress(".tbill"));

        MarketParams memory ethMkt = MarketParams(
            address(usdc), address(weth), json.readAddress(".ethOracle"), json.readAddress(".adaptiveIrm"), 0.86e18
        );
        MarketParams memory btcMkt = MarketParams(
            address(usdc), address(wbtc), json.readAddress(".btcOracle"), json.readAddress(".adaptiveIrm"), 0.86e18
        );
        MarketParams memory rwaMkt = MarketParams(
            address(usdc), address(tbill), json.readAddress(".tbillOracle"), json.readAddress(".fixedIrm5"), 0.915e18
        );

        // --- curator: accept caps + set queue
        vm.startBroadcast(PK0);
        vault.acceptCap(ethMkt);
        vault.acceptCap(btcMkt);
        vault.acceptCap(rwaMkt);
        Id[] memory q = new Id[](3);
        q[0] = rwaMkt.id();
        q[1] = ethMkt.id();
        q[2] = btcMkt.id();
        vault.setSupplyQueue(q);
        vm.stopBroadcast();

        // --- depositor: 4.5M USDC into the vault
        vm.startBroadcast(PK1);
        usdc.mint(vm.addr(PK1), 4_500_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(4_500_000e6, vm.addr(PK1));
        vm.stopBroadcast();

        // --- borrower A: conservative ETH loan (HF ~1.6)
        vm.startBroadcast(PK2);
        weth.mint(vm.addr(PK2), 500 ether);
        weth.approve(address(meridian), type(uint256).max);
        meridian.supplyCollateral(ethMkt, 500 ether, vm.addr(PK2), "");
        meridian.borrow(ethMkt, 800_000e6, 0, vm.addr(PK2), vm.addr(PK2));
        // RWA loop-style borrower: borrow USDC against tBILL at fixed 5%
        tbill.mint(vm.addr(PK2), 900_000e6);
        tbill.approve(address(meridian), type(uint256).max);
        meridian.supplyCollateral(rwaMkt, 900_000e6, vm.addr(PK2), "");
        meridian.borrow(rwaMkt, 750_000e6, 0, vm.addr(PK2), vm.addr(PK2));
        vm.stopBroadcast();

        // --- borrower B: aggressive ETH + BTC loans (HF ~1.03 / ~1.05) -> liquidation targets
        vm.startBroadcast(PK3);
        weth.mint(vm.addr(PK3), 300 ether);
        weth.approve(address(meridian), type(uint256).max);
        meridian.supplyCollateral(ethMkt, 300 ether, vm.addr(PK3), "");
        meridian.borrow(ethMkt, 750_000e6, 0, vm.addr(PK3), vm.addr(PK3));
        wbtc.mint(vm.addr(PK3), 20e8);
        wbtc.approve(address(meridian), type(uint256).max);
        meridian.supplyCollateral(btcMkt, 20e8, vm.addr(PK3), "");
        meridian.borrow(btcMkt, 980_000e6, 0, vm.addr(PK3), vm.addr(PK3));
        vm.stopBroadcast();

        console2.log("vault totalAssets", vault.totalAssets());
        console2.log("borrower B ETH HF", meridian.healthFactor(ethMkt, vm.addr(PK3)));
        console2.log("borrower B BTC HF", meridian.healthFactor(btcMkt, vm.addr(PK3)));
    }
}

import { meridianAbi, irmAbi } from "./abis.js";
import { deployment, publicClient, marketId, WAD, SECONDS_PER_YEAR, type MarketConfig } from "./config.js";

export type MarketState = {
  cfg: MarketConfig;
  id: `0x${string}`;
  totalSupplyAssets: bigint;
  totalBorrowAssets: bigint;
  utilization: bigint; // WAD
  borrowRatePerSec: bigint; // WAD
  borrowApr: number;
  supplyApr: number;
  fee: bigint;
  vaultSupply: bigint;
};

/** Snapshot one market's balances and rates (post-accrual view). */
export async function readMarket(cfg: MarketConfig, vault?: `0x${string}`): Promise<MarketState> {
  const id = marketId(cfg.params);
  const [raw, expected, vaultSupply] = await Promise.all([
    publicClient.readContract({ address: deployment.meridian, abi: meridianAbi, functionName: "market", args: [id] }),
    publicClient.readContract({ address: deployment.meridian, abi: meridianAbi, functionName: "expectedMarketBalances", args: [cfg.params] }),
    vault
      ? publicClient.readContract({ address: deployment.meridian, abi: meridianAbi, functionName: "expectedSupplyAssets", args: [cfg.params, vault] })
      : Promise.resolve(0n),
  ]);
  const [tsa, tss, tba, tbs, lastUpdate, fee] = raw;
  const borrowRatePerSec = await publicClient.readContract({
    address: cfg.params.irm,
    abi: irmAbi,
    functionName: "borrowRateView",
    args: [
      cfg.params,
      { totalSupplyAssets: tsa, totalSupplyShares: tss, totalBorrowAssets: tba, totalBorrowShares: tbs, lastUpdate, fee },
    ],
  });

  const totalSupplyAssets = expected[0];
  const totalBorrowAssets = expected[2];
  const utilization = totalSupplyAssets === 0n ? 0n : (totalBorrowAssets * WAD) / totalSupplyAssets;
  const borrowApr = Number(borrowRatePerSec * SECONDS_PER_YEAR) / 1e18;
  const supplyApr = borrowApr * (Number(utilization) / 1e18) * (1 - Number(fee) / 1e18);

  return { cfg, id, totalSupplyAssets, totalBorrowAssets, utilization, borrowRatePerSec, borrowApr, supplyApr, fee, vaultSupply };
}

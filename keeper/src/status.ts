/** Prints a one-shot snapshot of markets and the curator vault. */
import { vaultAbi } from "./abis.js";
import { MARKETS, deployment, publicClient, fmtUsd } from "./config.js";
import { readMarket } from "./markets.js";

const states = await Promise.all(MARKETS.map((m) => readMarket(m, deployment.vault)));
console.table(
  states.map((s) => ({
    market: s.cfg.name,
    supply: fmtUsd(s.totalSupplyAssets),
    borrow: fmtUsd(s.totalBorrowAssets),
    util: `${(Number(s.utilization) / 1e16).toFixed(1)}%`,
    borrowAPR: `${(s.borrowApr * 100).toFixed(2)}%`,
    supplyAPR: `${(s.supplyApr * 100).toFixed(2)}%`,
    vaultAlloc: fmtUsd(s.vaultSupply),
  })),
);

const [tvl, supply] = await Promise.all([
  publicClient.readContract({ address: deployment.vault, abi: vaultAbi, functionName: "totalAssets" }),
  publicClient.readContract({ address: deployment.vault, abi: vaultAbi, functionName: "totalSupply" }),
]);
const sharePrice = supply === 0n ? 1 : Number(tvl) / 1e6 / (Number(supply) / 1e18);
console.log(`Vault TVL ${fmtUsd(tvl)} USDC | share price ${sharePrice.toFixed(6)}`);

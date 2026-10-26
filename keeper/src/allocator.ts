/**
 * Vault allocator bot (the curator's "autopilot").
 *
 * Policy, evaluated every tick:
 *  - Liquidity guard: if a market the vault is in exceeds MAX_UTIL, pull liquidity
 *    *into* it from the most liquid market so depositors can still exit and the
 *    adaptive IRM isn't pinned at max.
 *  - Yield: otherwise, if the best supply APR beats the worst by > MIN_SPREAD,
 *    move a step of liquidity from worst to best, respecting caps and keeping the
 *    source market below MAX_UTIL after the move.
 *
 * Every move is a single atomic `reallocate` call and is simulated first.
 * Moving liquidity changes utilisation, which changes the rates, so step size is
 * bounded (STEP_BPS of vault TVL) to avoid oscillation.
 */
import { vaultAbi } from "./abis.js";
import { MARKETS, deployment, publicClient, walletClient, account, log, fmtUsd, WAD } from "./config.js";
import { readMarket, type MarketState } from "./markets.js";

const POLL_MS = Number(process.env.POLL_MS ?? 15000);
const MAX_UTIL = 920000000000000000n; // 92%
const MIN_SPREAD = 0.005; // 50 bps
const STEP_BPS = 500n; // move at most 5% of TVL per tick
const ONCE = process.argv.includes("--once");
const MAX_UINT = 2n ** 256n - 1n;

async function caps() {
  return Promise.all(
    MARKETS.map(async (m) => {
      const s = await readMarket(m, deployment.vault);
      const [cap, enabled] = await publicClient.readContract({
        address: deployment.vault,
        abi: vaultAbi,
        functionName: "config",
        args: [s.id],
      });
      return { s, cap: BigInt(cap), enabled };
    }),
  );
}

/** Max the vault can withdraw from `s` while keeping its utilisation <= MAX_UTIL. */
function withdrawable(s: MarketState): bigint {
  const minSupply = (s.totalBorrowAssets * WAD) / MAX_UTIL;
  const room = s.totalSupplyAssets > minSupply ? s.totalSupplyAssets - minSupply : 0n;
  return room < s.vaultSupply ? room : s.vaultSupply;
}

async function tick() {
  const rows = (await caps()).filter((r) => r.enabled);
  const tvl = await publicClient.readContract({ address: deployment.vault, abi: vaultAbi, functionName: "totalAssets" });
  const step = (tvl * STEP_BPS) / 10_000n;

  for (const { s } of rows) {
    log("alloc", `${s.cfg.name.padEnd(28)} util ${(Number(s.utilization) / 1e16).toFixed(1)}%  supplyAPR ${(s.supplyApr * 100).toFixed(2)}%  vault ${fmtUsd(s.vaultSupply)}`);
  }

  const room = (r: (typeof rows)[number]) => (r.cap > r.s.vaultSupply ? r.cap - r.s.vaultSupply : 0n);

  // 1) liquidity guard
  const stressed = rows.filter((r) => r.s.utilization > MAX_UTIL).sort((a, b) => Number(b.s.utilization - a.s.utilization))[0];
  let from: (typeof rows)[number] | undefined;
  let to: (typeof rows)[number] | undefined;
  let amount = 0n;

  if (stressed) {
    // supply needed so that util == MAX_UTIL
    const needed = (stressed.s.totalBorrowAssets * WAD) / MAX_UTIL - stressed.s.totalSupplyAssets;
    from = rows.filter((r) => r !== stressed).sort((a, b) => Number(withdrawable(b.s) - withdrawable(a.s)))[0];
    to = stressed;
    if (from) amount = [needed, withdrawable(from.s), room(stressed), step].reduce((a, b) => (a < b ? a : b));
    log("alloc", `liquidity guard: ${stressed.s.cfg.name} over ${Number(MAX_UTIL) / 1e16}% util`);
  } else {
    // 2) yield
    const sorted = [...rows].sort((a, b) => a.s.supplyApr - b.s.supplyApr);
    const worst = sorted.find((r) => withdrawable(r.s) > 0n);
    const best = [...sorted].reverse().find((r) => room(r) > 0n);
    if (worst && best && worst !== best && best.s.supplyApr - worst.s.supplyApr > MIN_SPREAD) {
      from = worst;
      to = best;
      amount = [withdrawable(worst.s), room(best), step].reduce((a, b) => (a < b ? a : b));
    }
  }

  if (!from || !to || amount < 1_000000n) {
    log("alloc", "no reallocation needed");
    return;
  }

  log("alloc", `moving ${fmtUsd(amount)} USDC: ${from.s.cfg.name} -> ${to.s.cfg.name}`);
  try {
    const { request } = await publicClient.simulateContract({
      account,
      address: deployment.vault,
      abi: vaultAbi,
      functionName: "reallocate",
      args: [
        [
          { params: from.s.cfg.params, assets: from.s.vaultSupply - amount },
          { params: to.s.cfg.params, assets: MAX_UINT },
        ],
      ],
    });
    const hash = await walletClient.writeContract(request);
    await publicClient.waitForTransactionReceipt({ hash });
    log("alloc", `✔ reallocated (${hash})`);
  } catch (e) {
    log("alloc", `✘ reallocation failed: ${(e as Error).message.split("\n")[0]}`);
  }
}

async function main() {
  log("alloc", `allocator ${account.address} managing vault ${deployment.vault}`);
  await tick();
  if (ONCE) return;
  setInterval(() => tick().catch((e) => log("alloc", `tick error: ${e}`)), POLL_MS);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

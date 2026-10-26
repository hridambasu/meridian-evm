/**
 * Liquidation keeper.
 *
 *  1. Discovers borrowers per market from `Borrow` / `SupplyCollateral` logs
 *     (incrementally, from the last scanned block).
 *  2. Each tick, batches health-factor reads through multicall-style parallel calls.
 *  3. For every position with HF < 1 it sizes the liquidation off-chain, simulates
 *     the FlashLiquidator call (catches unprofitable / raced liquidations for free),
 *     then submits it. Zero inventory required: Meridian pays collateral first and
 *     the callback swaps it into the repayment.
 *
 * Sizing: seize enough collateral to bring HF back above `TARGET_HF`, capped at the
 * full collateral (which realises bad debt if the position is underwater).
 */
import { parseAbiItem, type Address } from "viem";
import { meridianAbi, flashLiquidatorAbi } from "./abis.js";
import {
  MARKETS,
  deployment,
  publicClient,
  walletClient,
  account,
  marketId,
  log,
  fmtUsd,
  fmtWad,
  WAD,
  ORACLE_SCALE,
  type MarketConfig,
} from "./config.js";

const POLL_MS = Number(process.env.POLL_MS ?? 4000);
const TARGET_HF = 1_100000000000000000n; // aim to restore HF to 1.10
const MIN_PROFIT = BigInt(process.env.MIN_PROFIT ?? 1_000000); // 1 USDC
const ONCE = process.argv.includes("--once");

const borrowers = new Map<string, Set<Address>>(); // marketId -> borrowers
let fromBlock = 0n;

const borrowEvent = parseAbiItem(
  "event Borrow(bytes32 indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares)",
);

async function discoverBorrowers() {
  const toBlock = await publicClient.getBlockNumber();
  if (toBlock < fromBlock) return;
  const logs = await publicClient.getLogs({
    address: deployment.meridian,
    event: borrowEvent,
    fromBlock,
    toBlock,
  });
  for (const l of logs) {
    const id = l.args.id!;
    if (!borrowers.has(id)) borrowers.set(id, new Set());
    borrowers.get(id)!.add(l.args.onBehalf!);
  }
  fromBlock = toBlock + 1n;
}

async function liquidationIncentive(lltv: bigint) {
  return publicClient.readContract({
    address: deployment.meridian,
    abi: meridianAbi,
    functionName: "liquidationIncentiveFactor",
    args: [lltv],
  });
}

/**
 * Collateral to seize so that post-liquidation HF ~= TARGET_HF.
 *
 *   HF' = (C - s) * P * lltv / (D - s * P / LIF)
 *   solve HF' = T  =>  s = (T*D - C*P*lltv) / (P * (T/LIF - lltv))
 * where P is loan-per-collateral (scaled out of 1e36).
 */
function sizeSeize(collateral: bigint, debt: bigint, price: bigint, lltv: bigint, lif: bigint): bigint {
  const colValue = (collateral * price) / ORACLE_SCALE; // loan units
  const num = (TARGET_HF * debt) / WAD - (colValue * lltv) / WAD;
  const denomPerCol = (TARGET_HF * WAD) / lif - lltv; // WAD
  if (num <= 0n || denomPerCol <= 0n) return collateral;
  // s (collateral units) = num * 1e36 * WAD / (price * denomPerCol)
  const s = (num * ORACLE_SCALE * WAD) / (price * denomPerCol);
  return s >= collateral ? collateral : s + 1n;
}

async function checkMarket(m: MarketConfig) {
  const id = marketId(m.params);
  const set = borrowers.get(id);
  if (!set || set.size === 0) return;

  const addrs = [...set];
  const hfs = await Promise.all(
    addrs.map((a) =>
      publicClient.readContract({
        address: deployment.meridian,
        abi: meridianAbi,
        functionName: "healthFactor",
        args: [m.params, a],
      }),
    ),
  );

  for (let i = 0; i < addrs.length; i++) {
    const borrower = addrs[i];
    const hf = hfs[i];
    if (hf === 2n ** 256n - 1n) {
      set.delete(borrower); // fully repaid
      continue;
    }
    if (hf >= WAD) continue;

    const [[, , collateral], debt, price, lif] = await Promise.all([
      publicClient.readContract({ address: deployment.meridian, abi: meridianAbi, functionName: "position", args: [id, borrower] }),
      publicClient.readContract({ address: deployment.meridian, abi: meridianAbi, functionName: "expectedBorrowAssets", args: [m.params, borrower] }),
      publicClient.readContract({ address: m.params.oracle, abi: [{ type: "function", name: "price", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const, functionName: "price" }),
      liquidationIncentive(m.params.lltv),
    ]);

    const seize = sizeSeize(collateral, debt, price, m.params.lltv, lif);
    log("liq", `${m.name} ${borrower} HF=${fmtWad(hf)} debt=${fmtUsd(debt)} -> seizing ${seize} of ${collateral}`);

    try {
      const { request, result } = await publicClient.simulateContract({
        account,
        address: deployment.flashLiquidator,
        abi: flashLiquidatorAbi,
        functionName: "liquidate",
        args: [m.params, borrower, seize, m.swapper, MIN_PROFIT],
      });
      const hash = await walletClient.writeContract(request);
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      log("liq", `✔ liquidated ${borrower} in ${m.name}: profit ${fmtUsd(result)} USDC, gas ${receipt.gasUsed} (${hash})`);
    } catch (e) {
      log("liq", `✘ skipped ${borrower}: ${(e as Error).message.split("\n")[0]}`);
    }
  }
}

async function tick() {
  await discoverBorrowers();
  for (const m of MARKETS) await checkMarket(m);
}

async function main() {
  log("liq", `keeper ${account.address} watching ${MARKETS.length} markets on Meridian ${deployment.meridian}`);
  await tick();
  if (ONCE) return;
  setInterval(() => tick().catch((e) => log("liq", `tick error: ${e}`)), POLL_MS);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

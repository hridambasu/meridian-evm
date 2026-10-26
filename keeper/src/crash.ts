/**
 * Demo: simulate a market drawdown so the liquidation keeper has work.
 *   npm run crash -- 8     # drop ETH and BTC by 8%
 */
import { mockOracleAbi } from "./abis.js";
import { deployment, publicClient, walletClient, log } from "./config.js";

const pct = BigInt(Math.round(Number(process.argv[2] ?? "8") * 100)); // bps

async function drop(oracle: `0x${string}`, label: string) {
  const price = await publicClient.readContract({ address: oracle, abi: mockOracleAbi, functionName: "price" });
  const next = (price * (10_000n - pct)) / 10_000n;
  const hash = await walletClient.writeContract({ address: oracle, abi: mockOracleAbi, functionName: "setPrice", args: [next] });
  await publicClient.waitForTransactionReceipt({ hash });
  log("crash", `${label} price ${price} -> ${next} (-${Number(pct) / 100}%)`);
}

await drop(deployment.ethOracle, "ETH");
await drop(deployment.btcOracle, "BTC");

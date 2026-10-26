import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbiItem,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import deployment from "../../deployments/local.json";
import { meridianAbi, vaultAbi, irmAbi, erc20Abi } from "./abis";

const d = deployment as Record<string, Address>;
export { d as deployment };

const RPC = (import.meta.env.VITE_RPC_URL as string | undefined) ?? "http://127.0.0.1:8545";
export const publicClient = createPublicClient({ chain: foundry, transport: http(RPC) });

// Anvil account #1 — the demo depositor. Local devnet only.
export const devAccount = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
export const walletClient = createWalletClient({ account: devAccount, chain: foundry, transport: http(RPC) });

export type MarketParams = { loanToken: Address; collateralToken: Address; oracle: Address; irm: Address; lltv: bigint };
export type MarketDef = { name: string; collateral: string; params: MarketParams; rateModel: string };

export const MARKETS: MarketDef[] = [
  { name: "WETH", collateral: "WETH", rateModel: "Adaptive", params: { loanToken: d.usdc, collateralToken: d.weth, oracle: d.ethOracle, irm: d.adaptiveIrm, lltv: 860000000000000000n } },
  { name: "WBTC", collateral: "WBTC", rateModel: "Adaptive", params: { loanToken: d.usdc, collateralToken: d.wbtc, oracle: d.btcOracle, irm: d.adaptiveIrm, lltv: 860000000000000000n } },
  { name: "tBILL", collateral: "tBILL", rateModel: "Fixed 5%", params: { loanToken: d.usdc, collateralToken: d.tbill, oracle: d.tbillOracle, irm: d.fixedIrm5, lltv: 915000000000000000n } },
];

export const marketId = (p: MarketParams): Hex =>
  keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "address" }, { type: "address" }, { type: "uint256" }],
      [p.loanToken, p.collateralToken, p.oracle, p.irm, p.lltv],
    ),
  );

export type MarketRow = {
  def: MarketDef;
  supply: number;
  borrow: number;
  utilization: number;
  borrowApr: number;
  supplyApr: number;
  vaultSupply: number;
  cap: number;
};

export type PositionRow = { market: MarketDef; borrower: Address; debt: number; healthFactor: number };

export type Snapshot = {
  block: bigint;
  markets: MarketRow[];
  positions: PositionRow[];
  vault: { tvl: number; sharePrice: number; idle: number; fee: number; timelockDays: number };
  dev: { usdc: number; shares: number; maxWithdraw: number };
};

const usd = (x: bigint) => Number(x) / 1e6;
const borrowEvent = parseAbiItem(
  "event Borrow(bytes32 indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares)",
);

export async function loadSnapshot(): Promise<Snapshot> {
  const block = await publicClient.getBlockNumber();

  const markets = await Promise.all(
    MARKETS.map(async (def): Promise<MarketRow> => {
      const id = marketId(def.params);
      const [raw, expected, vaultSupply, cfg] = await Promise.all([
        publicClient.readContract({ address: d.meridian, abi: meridianAbi, functionName: "market", args: [id] }),
        publicClient.readContract({ address: d.meridian, abi: meridianAbi, functionName: "expectedMarketBalances", args: [def.params] }),
        publicClient.readContract({ address: d.meridian, abi: meridianAbi, functionName: "expectedSupplyAssets", args: [def.params, d.vault] }),
        publicClient.readContract({ address: d.vault, abi: vaultAbi, functionName: "config", args: [id] }),
      ]);
      const [tsa, tss, tba, tbs, lastUpdate, fee] = raw;
      const rate = await publicClient.readContract({
        address: def.params.irm,
        abi: irmAbi,
        functionName: "borrowRateView",
        args: [def.params, { totalSupplyAssets: tsa, totalSupplyShares: tss, totalBorrowAssets: tba, totalBorrowShares: tbs, lastUpdate, fee }],
      });
      const supply = usd(expected[0]);
      const borrow = usd(expected[2]);
      const utilization = supply === 0 ? 0 : borrow / supply;
      const borrowApr = (Number(rate) * 31_536_000) / 1e18;
      return {
        def,
        supply,
        borrow,
        utilization,
        borrowApr,
        supplyApr: borrowApr * utilization * (1 - Number(fee) / 1e18),
        vaultSupply: usd(vaultSupply),
        cap: usd(BigInt(cfg[0])),
      };
    }),
  );

  const logs = await publicClient.getLogs({ address: d.meridian, event: borrowEvent, fromBlock: 0n, toBlock: block });
  const pairs = new Map<string, { def: MarketDef; borrower: Address }>();
  for (const l of logs) {
    const def = MARKETS.find((m) => marketId(m.params) === l.args.id);
    if (def) pairs.set(`${l.args.id}-${l.args.onBehalf}`, { def, borrower: l.args.onBehalf! });
  }
  const positions = (
    await Promise.all(
      [...pairs.values()].map(async ({ def, borrower }) => {
        const [debt, hf] = await Promise.all([
          publicClient.readContract({ address: d.meridian, abi: meridianAbi, functionName: "expectedBorrowAssets", args: [def.params, borrower] }),
          publicClient.readContract({ address: d.meridian, abi: meridianAbi, functionName: "healthFactor", args: [def.params, borrower] }),
        ]);
        return { market: def, borrower, debt: usd(debt), healthFactor: Number(hf) / 1e18 };
      }),
    )
  )
    .filter((p) => p.debt > 0)
    .sort((a, b) => a.healthFactor - b.healthFactor);

  const [tvl, supply, idle, fee, timelock, devUsdc, devShares, maxW] = await Promise.all([
    publicClient.readContract({ address: d.vault, abi: vaultAbi, functionName: "totalAssets" }),
    publicClient.readContract({ address: d.vault, abi: vaultAbi, functionName: "totalSupply" }),
    publicClient.readContract({ address: d.usdc, abi: erc20Abi, functionName: "balanceOf", args: [d.vault] }),
    publicClient.readContract({ address: d.vault, abi: vaultAbi, functionName: "fee" }),
    publicClient.readContract({ address: d.vault, abi: vaultAbi, functionName: "timelock" }),
    publicClient.readContract({ address: d.usdc, abi: erc20Abi, functionName: "balanceOf", args: [devAccount.address] }),
    publicClient.readContract({ address: d.vault, abi: vaultAbi, functionName: "balanceOf", args: [devAccount.address] }),
    publicClient.readContract({ address: d.vault, abi: vaultAbi, functionName: "maxWithdraw", args: [devAccount.address] }),
  ]);

  return {
    block,
    markets,
    positions,
    vault: {
      tvl: usd(tvl),
      sharePrice: supply === 0n ? 1 : usd(tvl) / (Number(supply) / 1e18),
      idle: usd(idle),
      fee: Number(fee) / 1e18,
      timelockDays: Number(timelock) / 86400,
    },
    dev: { usdc: usd(devUsdc), shares: Number(devShares) / 1e18, maxWithdraw: usd(maxW) },
  };
}

export async function depositUsdc(amount: number) {
  const assets = BigInt(Math.round(amount * 1e6));
  const mint = await walletClient.writeContract({ address: d.usdc, abi: erc20Abi, functionName: "mint", args: [devAccount.address, assets] });
  await publicClient.waitForTransactionReceipt({ hash: mint });
  const approve = await walletClient.writeContract({ address: d.usdc, abi: erc20Abi, functionName: "approve", args: [d.vault, assets] });
  await publicClient.waitForTransactionReceipt({ hash: approve });
  const hash = await walletClient.writeContract({ address: d.vault, abi: vaultAbi, functionName: "deposit", args: [assets, devAccount.address] });
  await publicClient.waitForTransactionReceipt({ hash });
}

export async function withdrawUsdc(amount: number) {
  const assets = BigInt(Math.round(amount * 1e6));
  const hash = await walletClient.writeContract({
    address: d.vault,
    abi: vaultAbi,
    functionName: "withdraw",
    args: [assets, devAccount.address, devAccount.address],
  });
  await publicClient.waitForTransactionReceipt({ hash });
}

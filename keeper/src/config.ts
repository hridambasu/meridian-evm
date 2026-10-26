import { readFileSync } from "node:fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeAbiParameters,
  keccak256,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

export const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
// Anvil account #0 — local demo only. Use a dedicated hot key / KMS signer in production.
const PRIVATE_KEY = (process.env.KEEPER_PRIVATE_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") as Hex;

const deploymentPath = process.env.DEPLOYMENT ?? new URL("../../deployments/local.json", import.meta.url);
export const deployment = JSON.parse(readFileSync(deploymentPath, "utf8")) as Record<string, Address>;

export const account = privateKeyToAccount(PRIVATE_KEY);
export const publicClient = createPublicClient({ chain: foundry, transport: http(RPC_URL) });
export const walletClient = createWalletClient({ account, chain: foundry, transport: http(RPC_URL) });

export type MarketParams = {
  loanToken: Address;
  collateralToken: Address;
  oracle: Address;
  irm: Address;
  lltv: bigint;
};

export type MarketConfig = {
  name: string;
  params: MarketParams;
  collateralDecimals: number;
  swapper: Address;
};

export const marketId = (p: MarketParams): Hex =>
  keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
      ],
      [p.loanToken, p.collateralToken, p.oracle, p.irm, p.lltv],
    ),
  );

const d = deployment;
export const MARKETS: MarketConfig[] = [
  {
    name: "WETH/USDC 86%",
    params: { loanToken: d.usdc, collateralToken: d.weth, oracle: d.ethOracle, irm: d.adaptiveIrm, lltv: 860000000000000000n },
    collateralDecimals: 18,
    swapper: d.ethSwapper,
  },
  {
    name: "WBTC/USDC 86%",
    params: { loanToken: d.usdc, collateralToken: d.wbtc, oracle: d.btcOracle, irm: d.adaptiveIrm, lltv: 860000000000000000n },
    collateralDecimals: 8,
    swapper: d.btcSwapper,
  },
  {
    name: "tBILL/USDC 91.5% (fixed 5%)",
    params: { loanToken: d.usdc, collateralToken: d.tbill, oracle: d.tbillOracle, irm: d.fixedIrm5, lltv: 915000000000000000n },
    collateralDecimals: 6,
    swapper: d.rwaSwapper,
  },
];

export const WAD = 10n ** 18n;
export const ORACLE_SCALE = 10n ** 36n;
export const SECONDS_PER_YEAR = 365n * 24n * 3600n;

export const fmtUsd = (x: bigint, decimals = 6) =>
  (Number(x) / 10 ** decimals).toLocaleString("en-US", { maximumFractionDigits: 2 });
export const fmtWad = (x: bigint, digits = 4) => (Number(x) / 1e18).toFixed(digits);

export const log = (scope: string, msg: string) =>
  console.log(`${new Date().toISOString()} [${scope}] ${msg}`);

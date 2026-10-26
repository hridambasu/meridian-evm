# Meridian — isolated lending markets + curator vaults (EVM)

Meridian is a lending protocol for EVM chains built around the design that has
taken over DeFi credit in 2025–26: **permissionless isolated markets** at the
base layer, and **risk-curated ERC-4626 vaults** on top that allocate deposits
across those markets. Morpho Blue/Vaults, Euler v2 and Aave v4's spokes are all
variations on this design.

It ships end to end. The contracts are tested with unit, fuzz and invariant
tests. A flash-liquidation contract and a TypeScript keeper are included, along
with a vault allocator bot, a one-command Anvil demo, and a React dashboard.

```
                ┌────────────────────────────────────────────┐
 depositors ──▶ │  CuratorVault (ERC-4626)  "USDC Prime"      │
                │  caps · timelock · supply/withdraw queues  │◀── curator / allocator bot
                └──────┬───────────────┬──────────────┬──────┘
                       ▼               ▼              ▼
                ┌────────────┐  ┌────────────┐  ┌──────────────────┐
                │ WETH/USDC  │  │ WBTC/USDC  │  │ tBILL/USDC (RWA) │   isolated markets
                │ adaptive   │  │ adaptive   │  │ fixed 5% APR     │   in one singleton
                │ IRM, 86%   │  │ IRM, 86%   │  │ NAV oracle, 91.5%│   contract (Meridian)
                └─────┬──────┘  └─────┬──────┘  └────────┬─────────┘
                      └──── borrowers · liquidations ────┘◀── FlashLiquidator ◀── keeper bot
```

## What's in here

| Path | What it is |
|---|---|
| `src/Meridian.sol` | Singleton holding every isolated market `(loanToken, collateralToken, oracle, irm, lltv)`. Supply/withdraw, borrow/repay, collateral, liquidation with bad-debt realisation, free flash loans, callbacks, delegated authorisation, protocol fee. |
| `src/irm/AdaptiveCurveIrm.sol` | Kinked curve around 90% target utilisation whose level drifts exponentially while utilisation is off target. Markets find their own rate, with no governance tuning per market. |
| `src/irm/FixedRateIrm.sol` | Fixed borrow rate per deployment, for credit products that need rate certainty (e.g. borrowing USDC against T-bills). |
| `src/oracles/ChainlinkOracleAdapter.sol` | base/quote feed composition into the 1e36 price scale, with staleness and non-positive-answer guards. |
| `src/oracles/NavOracle.sol` | RWA oracle: issuer-published NAV with a heartbeat, a max per-update deviation (bounds a compromised updater key), and a lending haircut. |
| `src/vault/CuratorVault.sol` | ERC-4626 vault: owner/curator/allocator/guardian roles, per-market caps, timelocked cap raises and timelock reductions, guardian veto, supply/withdraw queues, atomic `reallocate`, performance fee on a high-water mark, liquidity-aware `maxWithdraw`, decimals offset against inflation attacks. |
| `src/periphery/FlashLiquidator.sol` | Capital-free liquidations. Meridian sends collateral first; the callback swaps it and repays, and the profit floor guards against slippage/MEV. |
| `test/` | 58 tests: unit, fuzz (512 runs), and a stateful invariant suite (borrow ≤ supply, token solvency, share accounting). |
| `script/Deploy.s.sol`, `script/Seed.s.sol` | Local deployment of three markets (incl. an RWA fixed-rate market) and a vault, plus positions at different health levels. |
| `keeper/` | viem bots: `liquidator` (event-indexed borrowers, off-chain liquidation sizing, simulate-then-send), `allocator` (liquidity guard + yield rebalancing within caps), `crash`, `status`. |
| `dashboard/` | React + viem curator dashboard: allocation bar, markets, borrowers closest to liquidation, deposit/withdraw. |

## Run it

Requires Foundry and Node 20+.

```bash
make test                 # forge test (58 tests)

# local end-to-end demo
make anvil                # terminal 1
make demo                 # terminal 2: build, deploy, advance past cap timelock, seed, print status
make ui                   # terminal 3: dashboard at http://localhost:5173
make keeper               # terminal 4: liquidation bot
make allocator            # terminal 5: vault allocator
make crash PCT=8          # drop ETH and BTC 8%, watch the keeper liquidate
```

Sample run (5% drop):

```
[liq] WETH/USDC 86% 0x90F7…b906 HF=0.9804 debt=750,000.08 -> seizing 162.40 of 300 WETH
[liq] ✔ liquidated … profit 18,051.1 USDC, gas 236610
```

## Design decisions worth discussing

- **Isolation over pooling.** A bad oracle or collateral token can only create bad debt inside its own market. `test_badDebtInOneMarket_isContained` shows a 66% BTC crash leaving the vault's WETH allocation untouched. Bad debt is realised immediately at liquidation and socialised only to that market's suppliers.
- **The risk lives in the vault, not the market.** Markets are immutable and permissionless. The curator chooses exposure through caps. Anything that increases risk (new market, higher cap, shorter timelock) waits behind the timelock so depositors can exit. Anything that reduces risk is instant. A guardian can veto pending changes.
- **Liquidation incentive tied to LLTV.** `LIF = min(1.15, 1/(1 − 0.3·(1 − lltv)))`. Riskier markets pay liquidators more, and high-LLTV markets pay less so liquidations don't push positions into insolvency.
- **Rounding always favours the protocol.** Debt rounds up, claims round down, and virtual shares/assets defeat share-inflation attacks. Fuzzed in `testFuzz_supplyWithdrawRoundTripNeverProfits` and `test_inflationAttack_isUnprofitable`.
- **Callbacks before the pull.** Liquidation transfers collateral, then calls back, then pulls the repayment. This enables zero-capital liquidations without reentrancy risk, because all state is final before the external calls.
- **RWA collateral.** The tBILL market uses a NAV oracle with deviation and staleness bounds plus a haircut, and a fixed-rate IRM. That is how T-bill-backed stablecoin credit lines are structured on-chain today.

## Production gaps (honest list)

Not audited. Oracles in the demo are mocks; mainnet would use the Chainlink adapter or a Redstone/Pyth equivalent with sequencer-uptime checks on L2s. The vault has no forced market removal path for markets that become illiquid, and does not support multiple pending caps per market. The keeper indexes from block 0 and should persist a cursor and use a private mempool (Flashbots) to submit. Gas has not been optimised beyond the compiler, `via_ir` is required for the liquidation path, and the IRM math is inspired by Morpho's published adaptive-curve design.

import { useCallback, useEffect, useState } from "react";
import { loadSnapshot, depositUsdc, withdrawUsdc, deployment, devAccount, type Snapshot, type MarketRow } from "./chain";

const money = (x: number) => x.toLocaleString("en-US", { maximumFractionDigits: 0 });
const pct = (x: number, d = 2) => `${(x * 100).toFixed(d)}%`;
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

function hfClass(hf: number) {
  if (hf < 1) return "hf hf-danger";
  if (hf < 1.1) return "hf hf-warn";
  return "hf hf-ok";
}

/** The vault's capital laid out across markets; each segment shaded by how much of that market is borrowed. */
function AllocationBar({ markets, idle, tvl }: { markets: MarketRow[]; idle: number; tvl: number }) {
  const segments = [
    ...markets.map((m) => ({ key: m.def.name, label: m.def.name, amount: m.vaultSupply, util: m.utilization, apr: m.supplyApr })),
    ...(idle > 1 ? [{ key: "idle", label: "Idle", amount: idle, util: 0, apr: 0 }] : []),
  ].filter((s) => s.amount > 0);

  return (
    <figure className="alloc" aria-label="Vault allocation by market">
      <div className="alloc-bar">
        {segments.map((s) => (
          <div key={s.key} className={`alloc-seg ${s.key === "idle" ? "alloc-idle" : ""}`} style={{ flexGrow: s.amount }}>
            <div className="alloc-util" style={{ height: `${Math.min(s.util, 1) * 100}%` }} />
          </div>
        ))}
      </div>
      <div className="alloc-labels">
        {segments.map((s) => (
          <div key={s.key} className="alloc-text" style={{ flexGrow: s.amount }}>
            <strong>{s.label}</strong>
            <span>${money(s.amount)}</span>
            {s.key !== "idle" && <span className="muted">{pct(s.util, 0)} lent out</span>}
          </div>
        ))}
      </div>
      <figcaption>
        Width is the vault&rsquo;s capital in each market (${money(tvl)} total). The darker fill shows how much of that market is currently borrowed.
      </figcaption>
    </figure>
  );
}

export default function App() {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [amount, setAmount] = useState("10000");
  const [busy, setBusy] = useState<"deposit" | "withdraw" | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setSnap(await loadSnapshot());
      setError(null);
    } catch (e) {
      setError("Can't reach the local chain. Start anvil and run the deploy and seed scripts, then reload.");
      console.error(e);
    }
  }, []);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 4000);
    return () => clearInterval(t);
  }, [refresh]);

  async function act(kind: "deposit" | "withdraw") {
    const n = Number(amount);
    if (!Number.isFinite(n) || n <= 0) {
      setNotice("Enter an amount above zero.");
      return;
    }
    setBusy(kind);
    setNotice(null);
    try {
      if (kind === "deposit") await depositUsdc(n);
      else await withdrawUsdc(n);
      setNotice(kind === "deposit" ? `Deposited ${money(n)} USDC.` : `Withdrew ${money(n)} USDC.`);
      await refresh();
    } catch (e) {
      const msg = (e as Error).message;
      setNotice(
        kind === "withdraw" && /NotEnoughLiquidity|ERC4626ExceededMaxWithdraw/.test(msg)
          ? "Not enough free liquidity to withdraw that much right now. Try the amount shown as available."
          : `Transaction failed: ${msg.split("\n")[0]}`,
      );
    } finally {
      setBusy(null);
    }
  }

  if (error) return <main className="shell"><p className="error">{error}</p></main>;
  if (!snap) return <main className="shell"><p className="muted">Reading markets…</p></main>;

  const { vault, markets, positions, dev } = snap;
  const blended = vault.tvl > 0 ? markets.reduce((a, m) => a + m.vaultSupply * m.supplyApr, 0) / vault.tvl : 0;

  return (
    <main className="shell">
      <header className="masthead">
        <div>
          <h1>Meridian USDC Prime</h1>
          <p className="lede">
            A curated vault lending USDC across {markets.length} isolated markets. Earning {pct(blended * (1 - vault.fee))} after a{" "}
            {pct(vault.fee, 0)} performance fee; cap increases wait {vault.timelockDays} day{vault.timelockDays === 1 ? "" : "s"}.
          </p>
        </div>
        <dl className="facts">
          <div><dt>Deposits</dt><dd>${money(vault.tvl)}</dd></div>
          <div><dt>Share price</dt><dd>{vault.sharePrice.toFixed(6)}</dd></div>
          <div><dt>Block</dt><dd>{snap.block.toString()}</dd></div>
        </dl>
      </header>

      <AllocationBar markets={markets} idle={vault.idle} tvl={vault.tvl} />

      <div className="grid">
        <section aria-labelledby="markets-h">
          <h2 id="markets-h">Markets</h2>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th scope="col">Collateral</th>
                  <th scope="col">Rate model</th>
                  <th scope="col" className="num">Liq. LTV</th>
                  <th scope="col" className="num">Supplied</th>
                  <th scope="col" className="num">Borrowed</th>
                  <th scope="col" className="num">Borrow APR</th>
                  <th scope="col" className="num">Supply APR</th>
                  <th scope="col" className="num">Vault / cap</th>
                </tr>
              </thead>
              <tbody>
                {markets.map((m) => (
                  <tr key={m.def.name}>
                    <th scope="row">{m.def.collateral}</th>
                    <td>{m.def.rateModel}</td>
                    <td className="num">{pct(Number(m.def.params.lltv) / 1e18, 1)}</td>
                    <td className="num">${money(m.supply)}</td>
                    <td className="num">${money(m.borrow)}</td>
                    <td className="num">{pct(m.borrowApr)}</td>
                    <td className="num">{pct(m.supplyApr)}</td>
                    <td className="num">
                      ${money(m.vaultSupply)} <span className="muted">/ {money(m.cap)}</span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <h2 id="pos-h">Borrowers closest to liquidation</h2>
          {positions.length === 0 ? (
            <p className="muted">No open loans. Run the seed script to open some.</p>
          ) : (
            <div className="table-wrap">
              <table aria-labelledby="pos-h">
                <thead>
                  <tr>
                    <th scope="col">Borrower</th>
                    <th scope="col">Market</th>
                    <th scope="col" className="num">Debt</th>
                    <th scope="col" className="num">Health</th>
                  </tr>
                </thead>
                <tbody>
                  {positions.map((p) => (
                    <tr key={`${p.market.name}-${p.borrower}`}>
                      <th scope="row" className="addr">{short(p.borrower)}</th>
                      <td>{p.market.collateral}</td>
                      <td className="num">${money(p.debt)}</td>
                      <td className="num">
                        <span className={hfClass(p.healthFactor)}>{p.healthFactor.toFixed(3)}</span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="muted small">Health below 1.000 can be liquidated. The keeper bot liquidates these automatically.</p>
        </section>

        <aside className="panel" aria-labelledby="act-h">
          <h2 id="act-h">Your position</h2>
          <p className="muted small">Uses Anvil test account {short(devAccount.address)}. Deposits mint test USDC first.</p>
          <dl className="mine">
            <div><dt>Vault shares</dt><dd>{dev.shares.toLocaleString("en-US", { maximumFractionDigits: 2 })}</dd></div>
            <div><dt>Worth</dt><dd>${money(dev.shares * vault.sharePrice)}</dd></div>
            <div><dt>Available to withdraw</dt><dd>${money(dev.maxWithdraw)}</dd></div>
          </dl>
          <label htmlFor="amt">Amount (USDC)</label>
          <input id="amt" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          <div className="buttons">
            <button onClick={() => act("deposit")} disabled={busy !== null}>
              {busy === "deposit" ? "Depositing…" : "Deposit"}
            </button>
            <button className="secondary" onClick={() => act("withdraw")} disabled={busy !== null}>
              {busy === "withdraw" ? "Withdrawing…" : "Withdraw"}
            </button>
          </div>
          {notice && <p className="notice" role="status">{notice}</p>}
          <p className="muted small contract">Vault contract {short(deployment.vault)}</p>
        </aside>
      </div>
    </main>
  );
}

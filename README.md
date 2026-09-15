# Charter

**A market for the leg of a Bitcoin bond that nobody gets paid for.**

A PoX-5 protocol bond needs two assets: sBTC and locked STX. Only one of them earns.
Charter lets those two legs come from two different people.

---

## The gap

A protocol bond is a dual-asset, 12-cycle (~6 month) commitment — a BTC timelock on Bitcoin L1
paired with an STX lock on Stacks. From the PoX-5 concepts page:

> "The BTC leg is the yield-bearing asset; **the STX leg gates participation and signing weight but
> earns nothing while paired**."

It is worse than nothing: paired STX also forfeits the STX-only staking tranche it would otherwise
have earned. Locking STX as bond ballast is a six-month negative-carry position.

Three consequences:

1. **A Bitcoin holder cannot participate without taking STX risk they never wanted.** The STX:BTC
   ratio is fixed per period by the Endowment — initially 5% — and the contract rejects any lock
   below it. So a BTC holder chasing ~3% BTC yield must first buy STX worth 5% of their position and
   hold it, unpaid, for six months.
2. **An STX holder can supply that leg but has no way to be paid for it.** Ballast is not scarce:
   the Genesis Bond's whole STX leg is 3.57M STX, against 441.5M STX stacked in cycle 143. What is
   missing is a price, not a supply.
3. **Where the legs are split today, it happens inside a single protocol.** StackingDAO's bond
   contract pairs stBTC depositors' sBTC with STX drawn from its own reserve. Xverse's community
   pool goes the other way: each member brings both legs, and its source says it "prevents one
   member's deliberate STX top-up from supporting another member."

There is no open, priced way to rent STX as bond ballast for a term. Charter is that.

## Why there is no option to lock extra STX

An earlier version let a charterer lock more than the minimum to buy payment priority. pox-5 does not
work that way. Its payout loop orders **bonds** by each bond's admin-set `stx-value-ratio` and pays
rewards per sat of BTC, so extra STX inside a bond buys no priority and earns nothing. The option was
removed, and `required-ustx-for` is now pox-5's own `min-ustx-for-sats-amount`.

## How it works

| | Ballast lender | Charterer |
|---|---|---|
| Brings | STX only | sBTC only |
| Wants | a fee for locking it | bond exposure without STX risk |
| Paid | a share of arriving yield | the remainder |
| Exposure | never holds BTC | never holds STX |

1. Lenders `submit-ballast-quote(ustx, rate-bps)` — locking STX and naming the share of bond yield
   they require.
2. Charterers `submit-charter(token, sats)`, committing sBTC. The STX required against it is
   pox-5's own minimum.
3. `form-bond(quote-ids)` fills quotes cheapest-first. The caller supplies the order and the
   contract verifies it is non-decreasing — the same pattern PoX-5 uses for bond payment ordering.
   Fill stops once the required ratio is met, and **everyone filled is paid the clearing rate**, so
   a lender is never punished for quoting honestly.
4. `receive-distribution(sats)` splits each arriving distribution at the clearing rate.

PoX-5 sees only the pool contract as the staker; every member-level record lives in this contract,
because "PoX-5 has no pool, envelope, or pro-rata mechanism of its own."

## Two properties that are structural, not incidental

**No oracle.** The only price-like input, `stx-value-ratio`, is a constant the protocol publishes
per period. The ballast price comes from the lenders' own quotes, the way an order book works. The
contract never has to value anything.

**No liquidation.** The fee is a share of yield that *arrives*, never a fixed obligation. If a
shortfall means nothing arrives, nothing is owed and no debt accrues. No position can go underwater,
so there is nothing to force-close. Two tests assert exactly this.

## Clarity 4

Built against Clarity 4 (`clarity_version = 4`, `epoch = "latest"`). Every outflow from the pool goes
through `as-contract?` with an explicit allowance:

```clarity
(unwrap! (as-contract? ((with-ft (contract-of token) "sbtc-token" amount))
           (try! (contract-call? token transfer amount tx-sender who none)))
         ERR_ALLOWANCE_VIOLATED)
```

`as-contract?` replaced Clarity 1's `as-contract` in SIP-033. It switches context to the contract
principal and then checks asset outflows against the granted allowances, reverting if any is
exceeded. That makes the post-condition part of the contract rather than something a caller has to
remember to attach: a payout that tried to move more than the amount being claimed fails inside the
pool. `current-contract`, also new in Clarity 4, replaces the `(as-contract tx-sender)` idiom for
naming the pool as a transfer recipient.

## Verified against mainnet

The ballast math is checked against every live registration, not inferred from prose:

```
$ ./scripts/verify-mainnet-parameters.sh

bond 1 [active]  stx_value_ratio 310237  minimum_stx_ratio 500 bps  target_rate 300 bps  registered 15/15
  pool rounding  SP8HK160YD5GHXP69VGA0TC7AQJ1X4CDW3XVERSE.sbtc-bond-staker-v1-1: +18 uSTX
  pool rounding  SPFCGF789WX1B737VQYAQ6BG3QYVMJGPDKRKYK00.esbee-dao-bond-staker-1: +3 uSTX
  15 registrations: 13 exactly on the floor, 2 rounded up, 0 outside tolerance
  note: bond totals (23,017,037,628 sats, 3,570,465,300,381 uSTX) disagree with its own
        registrations (23,017,662,628 sats, 3,570,465,300,381 uSTX): +625,000 sats.
        API inconsistency, not a formula error.
  yield 6.9053 BTC/yr on 230.1766 BTC, about 13,810,597 sats per distribution
  headroom: 300 / 500 = 60% a year on the ballast's own value
```

**`stx_value_ratio` is a price, uSTX per 100 sats, not the amount to lock.** The 5% the docs refer to
is a second parameter, `minimum_stx_ratio`, applied on top. This is pox-5's own
`min-ustx-for-sats-amount`, floor division included:

```
required_ustx = stx_value_ratio * sats / 100 * minimum_stx_ratio / 10000
```

An earlier version omitted the floor and demanded **20x too much STX**, returning a well-formed value
while doing it. The check now runs per registration. Individual registrants sit exactly on the floor;
the two sBTC pool contracts land a few uSTX above it because they round each member up. A formula
wrong in either direction fails. Tests pin four live registrations, including both non-round pool
positions, which is where floor and ceiling division disagree.

The script also surfaces an inconsistency in the API itself: the bond's locked BTC total is 625,000
sats lower than the sum of its own registrations.

**Headroom.** The bond pays 3% on the BTC leg, and the ballast is 5% of that leg's value, so a
charterer could pay up to 60% a year on the ballast's own value before the yield runs out. For scale,
StackingDAO advertises stSTX at up to 10% APY in STX rewards. If that is a lender's alternative, the
ballast fee is about a sixth of the bond's yield, before any move in the STX price.

## Status

Prototype. `clarinet check` passes with **zero warnings in `charter-pool`**; 16 tests pass.

```
clarinet check     # 3 contracts checked
npm install && npm test
```

| Contract | Role |
|---|---|
| `charter-pool.clar` | split-leg membership, quote fill, yield split, claims, maturity |
| `sip-010-trait.clar` | local trait copy for the test build |
| `mock-sbtc.clar` | 8-decimal test token standing in for `sbtc-token` |

`mock-sbtc` has an unrestricted `mint` and is **not for deployment** — it accounts for the only
`clarinet check` warnings in the project. Its fungible token is deliberately named `sbtc-token` so
the `with-ft` allowance literals are identical here and on mainnet. `set-sbtc-token` points the pool
at the canonical contract per network:

| Network | sbtc-token |
|---|---|
| Simnet / Devnet | `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token` |
| Testnet | `SN3VMHXEN64ZZF71JQ5VESXDWTR301XTTXGF4J8F1.sbtc-token` |
| Mainnet | `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token` |

## Known limitations

- **Period parameters are set by the operator, not read on-chain.** The values are verified against
  mainnet by `scripts/verify-mainnet-parameters.sh`, but `set-period-parameters` still trusts the
  operator to enter them. Reading them from PoX-5 directly is the next integration step.
- **Rounding dust stays in the pool.** The yield accumulator divides, so each claim rounds down by at
  most one sat. This is deliberate and asserted: total claims can never exceed what arrived, and the
  remainder is retained rather than overdrawn.
- **Canonical sBTC is declared as a Clarinet requirement but does not resolve.** Clarinet 3.23.2
  caches `sbtc-deposit` no matter which sBTC contract is requested — `clarinet requirements add
  ...sbtc-token` in a clean project still fetches `sbtc-deposit` — so the local `mock-sbtc` stands in
  for the test build. The requirements stay declared in `Clarinet.toml` for when the tooling is
  fixed; the pool references the canonical principal via `set-sbtc-token` on real networks.
- **Charter cannot form a mainnet bond by itself.** A pool must already be "the registered
  signer-manager for its signer key" and "on the bond's allowlist with a sufficient max-sats cap."
  Charter is built to sit in front of an existing whitelisted operator rather than to become one.
- **STX is held by the contract** in this prototype. Real bonds lock STX in place via PoX-5;
  aligning the two is the next integration step.
- Single bond per deployment. Multi-bond registry is future work.

## References

- [PoX-5 concepts](https://docs.stacks.co/pox-5/concepts) — dual-asset bond, 5% ratio, paired STX earns nothing
- [Protocol bond and rewards mechanics](https://docs.stacks.co/learn/bitcoin-staking/rewards-and-tranches) — payment ordering, shortfall, ~10% community capacity
- [Pools](https://docs.stacks.co/pox-5/development/pools) · [Bond pool operator guide](https://docs.stacks.co/operate/protocol-bonds/bond-pool-operator-guide)

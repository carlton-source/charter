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
2. **An STX holder owns the scarce input that gates bond capacity, and has no way to rent it out.**
3. **So bonds only work for entities holding both assets** — which is why the Genesis Bond is
   whitelisted institutions, why only ~10% of capacity is reserved for community pools, and why
   StackingDAO's community capacity sold out.

There is a missing price: what it costs to rent STX as bond ballast for a term.

## Ballast is not a threshold, it is a priority curve

The rewards contract pays bonds in **descending `stx-value-ratio` order** — most STX locked per unit
of BTC gets paid first — and a shortfall "falls entirely on the last bonds in the order."

So extra STX buys **payment seniority**, and in a shortfall the low-ratio bonds absorb the whole
loss while high-ratio bonds are paid in full. What is actually being traded is not a compliance
minimum but a term structure: how much yield a Bitcoin holder will surrender for how far up the
payment queue. `target-ratio-bps` is that knob.

## How it works

| | Ballast lender | Charterer |
|---|---|---|
| Brings | STX only | sBTC only |
| Wants | a fee for locking it | bond exposure without STX risk |
| Paid | a share of arriving yield | the remainder |
| Exposure | never holds BTC | never holds STX |

1. Lenders `submit-ballast-quote(ustx, rate-bps)` — locking STX and naming the share of bond yield
   they require.
2. Charterers `submit-charter(sats)` — committing sBTC and choosing a `target-ratio-bps`, where
   10000 is the protocol minimum and higher buys seniority.
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

## Status

Prototype. `clarinet check` passes with **zero warnings in `charter-pool`**; 13 tests pass.

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

- **The ratio formula needs validating against live PoX-5 parameters.** `required-ustx-for` mirrors
  `minUstxForSatsAmount` from `@stacks/bitcoin-staking`, but Clarinet 3.23.2 cannot compile against
  the live Clarity 6 contracts, so the reading adapter must live outside this build. Treated as an
  open item, not a settled one.
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

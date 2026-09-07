import { describe, expect, it, beforeEach } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const lenderA = accounts.get("wallet_1")!;   // holds STX only
const lenderB = accounts.get("wallet_2")!;   // holds STX only
const charterer = accounts.get("wallet_3")!; // holds sBTC only
const outsider = accounts.get("wallet_4")!;

const POOL = "charter-pool";
const SBTC = Cl.contractPrincipal(deployer, "mock-sbtc");

// stx-value-ratio is uSTX per 100 sats. 1000 => 10 uSTX per sat.
const RATIO = 1000;
const SATS = 100_000;          // charter leg
const REQUIRED_USTX = 1_000_000; // SATS * RATIO / 100, at target 10000 bps

const ok = (r: any) => { expect(r.result).toBeOk(expect.anything()); return r; };

function openPool(targetBps = 10000) {
  ok(simnet.callPublicFn(POOL, "set-period-parameters",
    [Cl.uint(RATIO), Cl.uint(targetBps)], deployer));
  ok(simnet.callPublicFn("mock-sbtc", "mint",
    [Cl.uint(10_000_000), Cl.principal(charterer)], deployer));
  ok(simnet.callPublicFn("mock-sbtc", "mint",
    [Cl.uint(10_000_000), Cl.principal(deployer)], deployer));
}

function quote(who: string, ustx: number, rateBps: number) {
  return simnet.callPublicFn(POOL, "submit-ballast-quote",
    [Cl.uint(ustx), Cl.uint(rateBps)], who);
}

describe("charter-pool: a bond neither party could open alone", () => {
  beforeEach(() => openPool());

  it("forms a bond from one STX-only member and one sBTC-only member", () => {
    ok(quote(lenderA, 600_000, 800));
    ok(quote(lenderB, 600_000, 1200));
    ok(simnet.callPublicFn(POOL, "submit-charter", [SBTC, Cl.uint(SATS)], charterer));

    const formed = simnet.callPublicFn(POOL, "form-bond",
      [Cl.list([Cl.uint(0), Cl.uint(1)])], deployer);
    expect(formed.result).toBeOk(
      Cl.tuple({
        "filled-ustx": Cl.uint(1_200_000),
        "clearing-rate-bps": Cl.uint(1200),
        "required-ustx": Cl.uint(REQUIRED_USTX),
      }));

    // The claim, stated as assertions: neither side supplied the other's asset.
    expect(simnet.callReadOnlyFn(POOL, "get-charter-position",
      [Cl.principal(lenderA)], deployer).result).toBeNone();
    expect(simnet.callReadOnlyFn(POOL, "get-ballast-position",
      [Cl.principal(charterer)], deployer).result).toBeNone();
  });

  it("splits a distribution between the two legs at the clearing rate", () => {
    ok(quote(lenderA, 600_000, 800));
    ok(quote(lenderB, 600_000, 1200));
    ok(simnet.callPublicFn(POOL, "submit-charter", [SBTC, Cl.uint(SATS)], charterer));
    ok(simnet.callPublicFn(POOL, "form-bond", [Cl.list([Cl.uint(0), Cl.uint(1)])], deployer));

    // One protocol distribution: 10,000 sats. Ballast takes 1200bps = 1,200.
    const dist = simnet.callPublicFn(POOL, "receive-distribution",
      [SBTC, Cl.uint(10_000)], deployer);
    expect(dist.result).toBeOk(
      Cl.tuple({ "to-ballast": Cl.uint(1_200), "to-charter": Cl.uint(8_800) }));

    // Ballast fee splits pro-rata by uSTX; equal stakes so 600 each.
    expect(simnet.callReadOnlyFn(POOL, "get-ballast-claimable",
      [Cl.principal(lenderA)], deployer).result).toBeUint(600);
    expect(simnet.callReadOnlyFn(POOL, "get-ballast-claimable",
      [Cl.principal(lenderB)], deployer).result).toBeUint(600);
    expect(simnet.callReadOnlyFn(POOL, "get-charter-claimable",
      [Cl.principal(charterer)], deployer).result).toBeUint(8_800);

    // And it is actually payable.
    expect(simnet.callPublicFn(POOL, "claim-ballast-yield", [SBTC], lenderA).result)
      .toBeOk(Cl.uint(600));
    expect(simnet.callPublicFn(POOL, "claim-charter-yield", [SBTC], charterer).result)
      .toBeOk(Cl.uint(8_800));
  });

  it("pays every filled lender the uniform clearing price, not their own quote", () => {
    ok(quote(lenderA, 600_000, 800));   // undercuts
    ok(quote(lenderB, 600_000, 1200));  // sets the clearing price
    ok(simnet.callPublicFn(POOL, "submit-charter", [SBTC, Cl.uint(SATS)], charterer));
    ok(simnet.callPublicFn(POOL, "form-bond", [Cl.list([Cl.uint(0), Cl.uint(1)])], deployer));
    ok(simnet.callPublicFn(POOL, "receive-distribution", [SBTC, Cl.uint(10_000)], deployer));

    // A quoted 800bps but is paid at 1200bps, so honest quoting is never punished.
    const a = simnet.callReadOnlyFn(POOL, "get-ballast-claimable",
      [Cl.principal(lenderA)], deployer).result;
    const b = simnet.callReadOnlyFn(POOL, "get-ballast-claimable",
      [Cl.principal(lenderB)], deployer).result;
    expect(a).toStrictEqual(b);
  });
});

describe("charter-pool: the protocol's constraints are enforced", () => {
  beforeEach(() => openPool());

  it("refuses to form a bond whose STX leg is below the required ratio", () => {
    ok(quote(lenderA, 500_000, 800)); // half of what 100k sats needs
    ok(simnet.callPublicFn(POOL, "submit-charter", [SBTC, Cl.uint(SATS)], charterer));
    expect(simnet.callPublicFn(POOL, "form-bond",
      [Cl.list([Cl.uint(0)])], deployer).result).toBeErr(Cl.uint(205)); // ERR_UNDERFILLED
  });

  it("rejects a fill order that is not non-decreasing in rate", () => {
    ok(quote(lenderA, 600_000, 1200));
    ok(quote(lenderB, 600_000, 800));
    ok(simnet.callPublicFn(POOL, "submit-charter", [SBTC, Cl.uint(SATS)], charterer));
    // Presented cheapest-last: the contract rejects it, mirroring PoX-5's own
    // ERR_INVALID_BOND_PERIOD_ORDERING check on bond payment order.
    expect(simnet.callPublicFn(POOL, "form-bond",
      [Cl.list([Cl.uint(0), Cl.uint(1)])], deployer).result).toBeErr(Cl.uint(204));
  });

  it("prices seniority: a higher target ratio demands more ballast", () => {
    const base = simnet.callReadOnlyFn(POOL, "required-ustx-for",
      [Cl.uint(SATS)], deployer).result;
    expect(base).toBeUint(REQUIRED_USTX);

    // 20% over the minimum buys a higher stx-value-ratio, which PoX-5 pays first.
    ok(simnet.callPublicFn(POOL, "set-period-parameters",
      [Cl.uint(RATIO), Cl.uint(12_000)], deployer));
    expect(simnet.callReadOnlyFn(POOL, "required-ustx-for",
      [Cl.uint(SATS)], deployer).result).toBeUint(1_200_000);
  });

  it("rejects a substituted token", () => {
    const notSbtc = Cl.contractPrincipal(deployer, "charter-pool");
    expect(simnet.callPublicFn(POOL, "submit-charter",
      [notSbtc, Cl.uint(SATS)], charterer).result).toBeErr(Cl.uint(208));
  });
});

describe("charter-pool: no debt, therefore no liquidation", () => {
  beforeEach(() => openPool());

  function formed() {
    ok(quote(lenderA, 1_000_000, 1500));
    ok(simnet.callPublicFn(POOL, "submit-charter", [SBTC, Cl.uint(SATS)], charterer));
    ok(simnet.callPublicFn(POOL, "form-bond", [Cl.list([Cl.uint(0)])], deployer));
  }

  it("owes the ballast lender nothing when no yield arrives", () => {
    formed();
    // A shortfall means no distribution. Nothing accrues to either side, and
    // crucially no obligation is carried forward as debt.
    expect(simnet.callReadOnlyFn(POOL, "get-ballast-claimable",
      [Cl.principal(lenderA)], deployer).result).toBeUint(0);
    expect(simnet.callPublicFn(POOL, "claim-ballast-yield", [SBTC], lenderA).result)
      .toBeErr(Cl.uint(207)); // ERR_NOTHING_CLAIMABLE
  });

  it("never lets the ballast fee exceed what actually arrived", () => {
    formed();
    ok(simnet.callPublicFn(POOL, "receive-distribution", [SBTC, Cl.uint(1_000)], deployer));
    const toBallast = 150; // 1500bps of 1,000
    expect(simnet.callReadOnlyFn(POOL, "get-ballast-claimable",
      [Cl.principal(lenderA)], deployer).result).toBeUint(toBallast);
    expect(simnet.callReadOnlyFn(POOL, "get-charter-claimable",
      [Cl.principal(charterer)], deployer).result).toBeUint(1_000 - toBallast);
  });

  it("returns both principals at maturity", () => {
    formed();
    ok(simnet.callPublicFn(POOL, "mature-bond", [], deployer));
    expect(simnet.callPublicFn(POOL, "claim-ballast-principal", [], lenderA).result)
      .toBeOk(Cl.uint(1_000_000));
    expect(simnet.callPublicFn(POOL, "claim-charter-principal", [SBTC], charterer).result)
      .toBeOk(Cl.uint(SATS));
  });
});

describe("charter-pool: allowance-checked payouts conserve the pool", () => {
  beforeEach(() => openPool());

  it("pays out exactly what was distributed and no more", () => {
    ok(quote(lenderA, 1_000_000, 1000));
    ok(simnet.callPublicFn(POOL, "submit-charter", [SBTC, Cl.uint(SATS)], charterer));
    ok(simnet.callPublicFn(POOL, "form-bond", [Cl.list([Cl.uint(0)])], deployer));
    ok(simnet.callPublicFn(POOL, "receive-distribution", [SBTC, Cl.uint(10_000)], deployer));

    // Every outflow runs through as-contract? with an explicit with-ft allowance,
    // so a payout larger than the claim would revert inside the contract.
    ok(simnet.callPublicFn(POOL, "claim-ballast-yield", [SBTC], lenderA));
    ok(simnet.callPublicFn(POOL, "claim-charter-yield", [SBTC], charterer));

    // Distribution fully paid out; only the charter principal remains escrowed.
    const poolBal = simnet.callReadOnlyFn("mock-sbtc", "get-balance",
      [Cl.contractPrincipal(deployer, "charter-pool")], deployer).result;
    expect(poolBal).toBeOk(Cl.uint(SATS));

    // And nothing is claimable twice.
    expect(simnet.callPublicFn(POOL, "claim-ballast-yield", [SBTC], lenderA).result)
      .toBeErr(Cl.uint(207));
  });
});

describe("charter-pool: unfilled ballast is not trapped", () => {
  beforeEach(() => openPool());

  it("lets a lender withdraw a quote that was never filled", () => {
    ok(quote(lenderA, 400_000, 900));
    expect(simnet.callPublicFn(POOL, "withdraw-unfilled-quote",
      [Cl.uint(0)], lenderA).result).toBeOk(Cl.uint(400_000));
  });

  it("does not let anyone else withdraw it", () => {
    ok(quote(lenderA, 400_000, 900));
    expect(simnet.callPublicFn(POOL, "withdraw-unfilled-quote",
      [Cl.uint(0)], outsider).result).toBeErr(Cl.uint(206));
  });
});

"""Verify charter-pool's ballast math against live PoX-5 bonds.

Checks, per bond:

1. Every registration locks at least the floor pox-5 enforces, and no
   more than 1 ppm above it. The floor is pox-5's own
   min-ustx-for-sats-amount, plain floor division:

       floor = stx_value_ratio * sats / 100 * minimum_stx_ratio / 10000

   Individual registrants sit on it exactly. Pool contracts round each
   member up separately, so they land a few uSTX above. A formula that
   was wrong in either direction fails: too high puts registrants below
   the floor, too low puts them far above it.

2. The bond-level locked totals agree with the sum of registrations.
   A disagreement here is an API inconsistency, reported, not a failure.

3. Headroom: the most a charterer could pay for ballast before the bond's
   yield runs out, as an annual rate on the ballast's own value.

stx_value_ratio is a price (uSTX per 100 sats), not the amount to lock.
Omitting minimum_stx_ratio over-demands STX by 20x and still returns a
well-formed number, which is why this check exists.
"""
import json
import sys
import urllib.request

API = sys.argv[1] if len(sys.argv) > 1 else "https://api.hiro.so"
MAX_EXCESS_PPM = 1


def get(path):
    with urllib.request.urlopen(API + path, timeout=30) as r:
        return json.load(r)


def registrations(index):
    rows, cursor = [], None
    while True:
        q = "/extended/v3/staking/bonds/{}/registrations?limit=50".format(index)
        if cursor:
            q += "&cursor=" + cursor
        page = get(q)
        rows += page.get("results", [])
        cursor = (page.get("cursor") or {}).get("next")
        if not cursor:
            return rows


def floor_ustx(sats, svr, minbps):
    return svr * sats // 100 * minbps // 10000


def main():
    failures = 0
    for b in get("/extended/v3/staking/bonds?limit=20").get("results", []):
        p = b["parameters"]
        svr, minbps = int(p["stx_value_ratio"]), int(p["minimum_stx_ratio"])
        rate = int(p["target_rate_bps"])
        reg = b.get("registrations", {})
        print("\nbond {} [{}]  stx_value_ratio {}  minimum_stx_ratio {} bps  "
              "target_rate {} bps  registered {}/{}".format(
                  b["index"], b["status"], svr, minbps, rate,
                  reg.get("registered_count"), reg.get("allowed_count")))

        rows = registrations(b["index"])
        if not rows:
            print("  no registrations yet; nothing to check")
            continue

        exact = above = 0
        sum_sats = sum_ustx = sum_excess = 0
        for r in rows:
            sats, ustx = int(r["balances"]["btc"]), int(r["balances"]["stx"])
            fl = floor_ustx(sats, svr, minbps)
            excess = ustx - fl
            sum_sats, sum_ustx, sum_excess = sum_sats + sats, sum_ustx + ustx, sum_excess + excess
            if excess < 0 or (fl and excess * 1_000_000 > fl * MAX_EXCESS_PPM):
                print("  FAIL {} {}: {:,} sats locks {:,} uSTX, floor {:,}".format(
                    r["type"], r["staker"], sats, ustx, fl))
                failures += 1
            elif excess == 0:
                exact += 1
            else:
                above += 1
                print("  pool rounding  {}: +{} uSTX".format(r["staker"], excess))
        print("  {} registrations: {} exactly on the floor, {} rounded up, "
              "{} outside tolerance".format(len(rows), exact, above,
                                            len(rows) - exact - above))

        locked = b.get("balances", {}).get("locked", {})
        agg_sats, agg_ustx = int(locked.get("btc", 0)), int(locked.get("stx", 0))
        if (agg_sats, agg_ustx) != (sum_sats, sum_ustx):
            gap_sats = sum_sats - agg_sats
            print("  note: bond totals ({:,} sats, {:,} uSTX) disagree with its own "
                  "registrations ({:,} sats, {:,} uSTX): {:+,} sats. API inconsistency, "
                  "not a formula error.".format(agg_sats, agg_ustx, sum_sats, sum_ustx, gap_sats))

        yearly = sum_sats * rate // 10000
        print("  yield {:.4f} BTC/yr on {:,.4f} BTC, about {:,} sats per distribution".format(
            yearly / 1e8, sum_sats / 1e8, yearly // 50))
        print("  headroom: {} / {} = {:.0f}% a year on the ballast's own value, the most a "
              "charterer could pay for ballast before yield runs out".format(
                  rate, minbps, rate / minbps * 100))

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

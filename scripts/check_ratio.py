"""Re-derive charter-pool's required-ustx-for from live PoX-5 bond parameters.

    required = sats * stx_value_ratio / 100 * minimum_stx_ratio / 10000

stx_value_ratio is a PRICE (uSTX per 100 sats), not the amount to lock.
Dropping minimum_stx_ratio over-demands STX by 20x -- and returns a
well-formed number while doing it, which is why this check exists.
"""
import json
import sys


def is_num(v):
    return v is not None and str(v).isdigit()


def main():
    data = json.load(sys.stdin)
    rows = data.get("results", [])
    if not rows:
        sys.exit("no bonds returned")

    failures = 0
    for b in rows:
        p = b.get("parameters", {})
        locked = b.get("balances", {}).get("locked", {})
        reg = b.get("registrations", {})
        svr, minbps = p.get("stx_value_ratio"), p.get("minimum_stx_ratio")
        sats, ustx = locked.get("btc"), locked.get("stx")

        print("\nbond {} [{}]  pox={}".format(
            b.get("index"), b.get("status"), b.get("pox_version")))
        print("  stx_value_ratio {}   minimum_stx_ratio {} bps   target_rate {} bps".format(
            svr, minbps, p.get("target_rate_bps")))
        print("  capacity {:,} sats   registered {}/{}".format(
            int(p.get("btc_capacity", 0)), reg.get("registered_count"),
            reg.get("allowed_count")))

        if not all(is_num(v) for v in (svr, minbps, sats, ustx)) or int(sats) == 0:
            print("  no locked position yet; nothing to check")
            continue

        sats, ustx = int(sats), int(ustx)
        derived = sats * int(svr) // 100 * int(minbps) // 10000
        naive = sats * int(svr) // 100
        print("  locked {:,} sats against {:,} uSTX".format(sats, ustx))
        print("  derived {:,} uSTX".format(derived))
        if derived == ustx:
            print("  MATCH  (without the ratio floor: {:,}, {:.1f}x too high)".format(
                naive, naive / ustx))
        else:
            print("  MISMATCH: off by {:,} uSTX".format(derived - ustx))
            failures += 1

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

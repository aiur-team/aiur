# Simulated power for a two-sided Mann-Whitney U test (normal approximation), resampling the baseline.
import csv, sys, random, math, json, statistics
R = list(csv.DictReader(open(sys.argv[1])))
def col(f, key):
    return [float(r[key]) for r in R if f(r) and r[key] not in ("", "None")]
elig = lambda r: r["eligible_for_gap"] == "True"
notlate = lambda r: r["late_linked"] != "True"
from datetime import datetime
def ts(s): return datetime.fromisoformat(s.replace("Z", "+00:00"))
chain = [ (ts(r["pr_merged"]) - ts(r["last_blocker_pr_opened"])).total_seconds()/3600 for r in R if elig(r) and r["pr_merged"] and r["last_blocker_pr_opened"]]
data = {"gap": col(elig, "blocker_merge_to_dependent_start_h"),
        "start_to_merge": col(notlate, "start_to_merge_h"),
        "chain_lead_time": chain}
def mwu_p(a, b):
    allv = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks = [0.0] * len(allv); i = 0
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]: j += 1
        for k in range(i, j + 1): ranks[k] = (i + j) / 2 + 1
        i = j + 1
    r1 = sum(r for r, (v, g) in zip(ranks, allv) if g == 0)
    n1, n2 = len(a), len(b); u = r1 - n1 * (n1 + 1) / 2
    mu = n1 * n2 / 2; sd = math.sqrt(n1 * n2 * (n1 + n2 + 1) / 12)
    z = (u - mu) / sd if sd else 0
    return math.erfc(abs(z) / math.sqrt(2))
random.seed(7)
res = {"chain_lead_time_baseline": {"n": len(chain), "median_h": round(statistics.median(chain), 3) if chain else None,
        "p25_h": round(statistics.quantiles(chain, n=4, method="inclusive")[0], 3), "p75_h": round(statistics.quantiles(chain, n=4, method="inclusive")[2], 3)}}
for name, base in data.items():
    tbl = {}
    for factor in (0.5, 0.67, 0.8):
        row = {}
        for n in (10, 15, 20, 30, 40, 60):
            hits = 0; sims = 1000
            for _ in range(sims):
                a = [random.choice(base) for _ in range(n)]
                b = [random.choice(base) * factor for _ in range(n)]
                hits += mwu_p(a, b) < 0.05
            row[n] = round(hits / sims, 2)
        tbl["x%.2f" % factor] = row
    res[name] = {"baseline_n": len(base), "power_by_n_per_arm": tbl}
json.dump(res, open(sys.argv[2], "w"), indent=2); print(json.dumps(res, indent=1))

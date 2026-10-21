"""Summarise one or more run directories. Usage: analyze.py DIR...

Works on output from both run.sh (driver.py) and live.py. Also writes the
summaries as JSON to summary.json next to the first DIR.
"""

import bisect
import collections
import json
import sys
from pathlib import Path


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = min(len(xs) - 1, max(0, round(p / 100 * (len(xs) - 1))))
    return xs[k]


def load(run):
    marks = [json.loads(l) for l in (run / "marks.jsonl").read_text().splitlines()]
    speech = []
    for line in (run / "speech.log").read_text(errors="replace").splitlines():
        # Multi-line utterances continue on lines without a timestamp.
        t, _, text = line.partition("\t")
        try:
            speech.append((float(t), text))
        except ValueError:
            pass
    names = json.loads((run / "names.json").read_text())
    by_comm = collections.defaultdict(set)
    for name, info in names.items():
        by_comm[info["comm"]].add(name)
    orca = by_comm["orca"]
    term = set()
    for comm in ("ghostty", "kgx", "ptyxis"):
        term |= by_comm.get(comm, set())
    sigs, calls = [], []
    pending = {}
    for line in (run / "bus.log").read_text(errors="replace").splitlines():
        f = line.split("\t")
        if not f or f[0].startswith("#") or len(f) < 6:
            continue
        kind, ts = f[0], float(f[1])
        if kind == "sig":
            sigs.append((ts, f[3], f[7] if len(f) > 7 else ""))
        elif kind == "mc":
            pending[(f[3], f[2])] = (ts, f[3], f[4], f[7] if len(f) > 7 else "")
        elif kind in ("mr", "err"):
            key = (f[4], f[5])  # (original sender, reply_serial)
            mc = pending.pop(key, None)
            if mc:
                calls.append((mc[0], ts - mc[0], mc[1], mc[2], mc[3], kind))
    sigs.sort()
    calls.sort()
    return marks, speech, orca, term, sigs, calls


def phase_windows(marks):
    w = collections.OrderedDict()
    for m in marks:
        if m["kind"] == "phase":
            w.setdefault(m["name"], {})[m["state"]] = m
    return w


def first_after(times, t):
    i = bisect.bisect_left(times, t)
    return times[i] if i < len(times) else None


def analyze(run):
    marks, speech, orca, term, sigs, calls = load(run)
    term_tc = [s[0] for s in sigs if s[1] in term and s[2] == "TextChanged"]
    cpu = {m["label"]: m for m in marks if m["kind"] == "cpu"}
    out = {"run": run.name, "phases": {}}
    for name, st in phase_windows(marks).items():
        if "end" not in st:
            print(f"{run.name}: phase {name} never finished, skipped", file=sys.stderr)
            continue
        t0 = st["start"]["t"]
        t1 = st["end"]["t"]
        res = {}
        c0, c1 = cpu.get(f"{name}:start"), cpu.get(f"{name}:end")
        if c0 and c1:
            res["cpu_s"] = {k: (c1[k] - c0[k]) / 100 for k in ("orca", "term", "registryd")}
        o_calls = [c for c in calls if t0 <= c[0] <= t1 and c[2] in orca and c[3] in term]
        res["orca_calls_to_term"] = len(o_calls)
        lat = [c[1] for c in o_calls]
        res["reply_ms"] = {"p50": pct(lat, 50) * 1000, "p99": pct(lat, 99) * 1000,
                           "max": (max(lat) if lat else float("nan")) * 1000,
                           "sum_s": sum(lat)}
        res["calls_by_member"] = collections.Counter(c[4] for c in o_calls).most_common(8)
        res["term_text_changed"] = sum(1 for t in term_tc if t0 <= t <= t1)
        res["term_signals"] = collections.Counter(
            s[2] for s in sigs if t0 <= s[0] <= t1 and s[1] in term).most_common(6)
        if c0 and c1 and "threads" in c1:
            res["term_threads_s"] = {k: (v - c0["threads"].get(k, 0)) / 100
                                     for k, v in c1["threads"].items()
                                     if v - c0["threads"].get(k, 0) > 1}
        sp = [s for s in speech if t0 <= s[0] <= t1]
        res["utterances"] = len(sp)
        res["spoken_chars"] = sum(len(s[1]) for s in sp)

        keys = [m for m in marks if m["kind"] in ("key", "probe") and m.get("phase") == name]
        key_lat, echo_lat, missing = [], [], 0
        for k in keys:
            want = "space" if k["ch"] == " " else k["ch"]
            hit = next((s for s in speech if s[0] >= k["t_press"] and s[1].strip() == want), None)
            if hit and hit[0] - k["t_press"] < 60:
                key_lat.append((k, hit[0] - k["t_press"]))
            else:
                missing += 1
            e = first_after(term_tc, k["t_press"])
            if e is not None and e - k["t_press"] < 5:
                echo_lat.append(e - k["t_press"])
        if keys:
            lats = [l for _, l in key_lat]
            res["key_to_speech_ms"] = {"n": len(lats), "missing": missing,
                                       "p50": pct(lats, 50) * 1000, "p90": pct(lats, 90) * 1000,
                                       "max": (max(lats) if lats else float("nan")) * 1000}
            res["key_to_term_event_ms"] = {"p50": pct(echo_lat, 50) * 1000, "p90": pct(echo_lat, 90) * 1000}
            res["probes"] = [(k["ch"], k.get("during"), round(l * 1000)) for k, l in key_lat
                             if k["kind"] == "probe"]
        probe_file = run / "probe.jsonl"
        if probe_file.exists():
            pr = [json.loads(l) for l in probe_file.read_text().splitlines() if l.strip()]
            for call in ("GetCharacterCount", "GetText"):
                xs = [p["lat"] for p in pr if p["call"] == call and t0 <= p["t"] <= t1]
                res[f"probe_{call}_ms"] = {"n": len(xs), "p50": pct(xs, 50) * 1000,
                                           "p99": pct(xs, 99) * 1000,
                                           "max": (max(xs) if xs else float("nan")) * 1000}
        if "producer-done" in st:
            done = st["producer-done"].get("t_done")
            busy = st["end"].get("orca_last_busy")
            sent = st["cmd-sent"]["t"]
            res["producer_s"] = done - sent if done else None
            res["orca_busy_after_done_s"] = (busy - done) if (busy and done) else None
            during = [t for t in term_tc if sent <= t <= (done or sent)]
            res["term_text_changed_per_s"] = len(during) / max(1e-3, (done or sent) - sent)
        out["phases"][name] = res
    return out


def show(r):
    print(f"=== {r['run']}")
    for name, p in r["phases"].items():
        print(f"  -- {name}")
        if "cpu_s" in p:
            c = p["cpu_s"]
            print(f"     cpu s: orca {c['orca']:.2f}  term {c['term']:.2f}  registryd {c['registryd']:.2f}")
            if p.get("term_threads_s"):
                print(f"     term threads s: {p['term_threads_s']}")
        if p.get("producer_s") is not None:
            busy = p["orca_busy_after_done_s"]
            busy = f"{busy:.2f}s" if busy is not None else "n/a"
            print(f"     producer ran {p['producer_s']:.2f}s; Orca still busy {busy} after it finished")
            print(f"     terminal TextChanged: {p['term_text_changed']} total, {p['term_text_changed_per_s']:.1f}/s while producing")
        else:
            print(f"     terminal TextChanged: {p['term_text_changed']}")
        rm = p["reply_ms"]
        print(f"     Orca->term calls {p['orca_calls_to_term']}, reply p50 {rm['p50']:.2f}ms p99 {rm['p99']:.2f}ms max {rm['max']:.1f}ms, total blocked {rm['sum_s']:.2f}s")
        print(f"     by member: {p['calls_by_member']}")
        for call in ("GetCharacterCount", "GetText"):
            q = p.get(f"probe_{call}_ms")
            if q and q["n"]:
                print(f"     probe {call:17s} n={q['n']:4d} p50 {q['p50']:.2f}ms p99 {q['p99']:.1f}ms max {q['max']:.1f}ms")
        print(f"     speech: {p['utterances']} utterances, {p['spoken_chars']} chars")
        if "key_to_speech_ms" in p:
            k = p["key_to_speech_ms"]
            e = p["key_to_term_event_ms"]
            print(f"     key->speech  n={k['n']} missing={k['missing']} p50 {k['p50']:.0f}ms p90 {k['p90']:.0f}ms max {k['max']:.0f}ms")
            print(f"     key->term TextChanged p50 {e['p50']:.0f}ms p90 {e['p90']:.0f}ms")
            if p.get("probes"):
                print(f"     probes (ch, during, ms): {p['probes']}")


if __name__ == "__main__":
    results = [analyze(Path(a)) for a in sys.argv[1:]]
    for r in results:
        show(r)
    Path(sys.argv[1]).parent.joinpath("summary.json").write_text(json.dumps(results, indent=1, default=str))

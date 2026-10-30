"""Each mutation is a mistake TLA+ only reports at run time, if the run happens to reach it.
Quint has to reject every one of them before anything runs."""
import pathlib, subprocess, sys, tempfile

SPEC = pathlib.Path(__file__).with_name("looper.qnt").read_text()

MUTATIONS = {
    "a press kind with no handler (non-exhaustive match)": (
        "    | VariantPress(v) => { ...intent, asset: { ...intent.asset, variant: v } }\n", ""),
    "the TLA+ idiom of a string sentinel for 'no fade'": (
        "pure def isFading(v: Voice): bool = v.fadeOut != None",
        'pure def isFading(v: Voice): bool = v.fadeOut != "none"'),
    "a misspelled record field": (
        "f.until > t | None => true", "f.untill > t | None => true"),
    "an int compared with a bool": (
        "presses < MaxPresses,", "presses < true,"),
    "a pure function that reads the clock": (
        "pure def dispose(s: Machine, t: int): Machine =\n    val kept = s.voices.filter(v => match v.fadeOut { | Some(f) => f.until > t",
        "pure def dispose(s: Machine, t: int): Machine =\n    val kept = s.voices.filter(v => match v.fadeOut { | Some(f) => f.until > now"),
    "a reducer that writes state directly": (
        "pure def settle(s: Machine, t: int): Machine =\n    val d = dispose(s, t)\n    if (commitDue(d, t)) commit(d, t) else d",
        "action settleInPlace(t: int): bool = m' = dispose(m, t)\n  pure def settle(s: Machine, t: int): Machine =\n    if (settleInPlace(t)) s else s"),
    "a Fade where a Voice belongs": (
        "if (s.intent.playing) faded.union(Set(fresh)) else faded",
        "if (s.intent.playing) faded.union(Set({ from: at, until: at })) else faded"),
}

failed = False
for name, (old, new) in MUTATIONS.items():
    assert SPEC.count(old) == 1, f"mutation anchor not found exactly once: {name}"
    with tempfile.TemporaryDirectory() as d:
        f = pathlib.Path(d, "looper.qnt")
        f.write_text(SPEC.replace(old, new))
        r = subprocess.run(["quint", "typecheck", str(f)], capture_output=True, text=True)
    out = r.stdout + r.stderr
    code = next((w.strip("[]:") for w in out.split() if w.startswith("[QNT")), "-")
    verdict = "rejected" if r.returncode != 0 else "ACCEPTED"
    failed |= r.returncode == 0
    print(f"{verdict:9} {code:8} {name}")
sys.exit(1 if failed else 0)

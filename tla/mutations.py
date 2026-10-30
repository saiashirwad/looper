"""The same kinds of mistake as ../quint/mutations.py, made in Looper.tla.
SANY parses and resolves names, it does not type-check, so each one gets past it.
TLC only notices when, and if, it evaluates the broken expression."""
import pathlib, re, subprocess, tempfile

HERE = pathlib.Path(__file__).parent
SPEC = (HERE / "Looper.tla").read_text()
CFG = (HERE / "Looper.cfg").read_text()

MUTATIONS = {
    "a misspelled record field": ("v.fadeEnd <= t)}", "v.fadeEndd <= t)}"),
    "a string sentinel compared with a boolean": ("Tail(s) == {v \\in s.voices : ~v.fading}",
                                                  'Tail(s) == {v \\in s.voices : v.fading = "none"}'),
    "an int compared with a model value": ("s.intent.asset.pattern = p.value", "s.intent.asset.pattern = 1"),
}

for name, (old, new) in MUTATIONS.items():
    assert SPEC.count(old) == 1, name
    with tempfile.TemporaryDirectory() as d:
        pathlib.Path(d, "Looper.tla").write_text(SPEC.replace(old, new))
        pathlib.Path(d, "Looper.cfg").write_text(CFG)
        sany = subprocess.run(["sany", "Looper.tla"], cwd=d, capture_output=True, text=True)
        tlc = subprocess.run(["tlc", "Looper.tla", "-config", "Looper.cfg", "-workers", "auto"],
                             cwd=d, capture_output=True, text=True)
    sany_ok = "error" not in (sany.stdout + sany.stderr).lower()
    states = re.search(r"(\d+) distinct states found", tlc.stdout)
    tlc_verdict = ("finds nothing" if "No error has been found" in tlc.stdout
                   else f"fails at run time after {states.group(1) if states else '?'} states")
    print(f"SANY {'accepts' if sany_ok else 'rejects'}; TLC {tlc_verdict}: {name}")

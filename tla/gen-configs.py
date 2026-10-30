"""Writes every Looper.*.cfg. Each run differs from the default in a few constants."""
DEFAULT = dict(Patterns="{p1, p2, p3}", Variants="{v1, v2}", Tick=4, Loop=8, Lead=1,
               DecideAhead=2, Crossfade=1, LongFade=2, MaxLate=0, MaxTime=20,
               MaxPresses=3, ShortenBoundBy=0)
INVARIANTS = ["SingleTail", "AtMostTwoVoices", "GridExistsExactlyWhileSomethingIsAlive",
              "EveryVoiceIsOnTheGrid", "NeverTwoLoopsAtFullVolume", "RespondsWithinBound"]
RUNS = {
    "Looper": ("pass", "Real orderings, on-time timer.", {}),
    "Looper.late-timer": ("pass", "Timer late by up to DecideAhead - Lead: costs nothing.", dict(MaxLate=1)),
    "Looper.timer-starves": ("fail RespondsWithinBound", "Timer always later than DecideAhead - Lead: every boundary is missed, forever.",
                                dict(DecideAhead=1, MaxLate=1)),
    "Looper.bound-is-tight": ("fail RespondsWithinBound", "One unit less than ResponseBound is not enough.",
                              dict(ShortenBoundBy=1)),
    "Looper.long-fade": ("fail AtMostTwoVoices", "fadeToSilence longer than a tick: what breaks?",
                         dict(LongFade=9, MaxTime=24, MaxPresses=4)),
}
for name, (expect, desc, over) in RUNS.items():
    c = {**DEFAULT, **over}
    lines = [f"\\* EXPECT: {expect}", f"\\* {desc}", "SPECIFICATION Spec", "CONSTANTS"]
    lines += [f"  {k} = {v}" for k, v in c.items()]
    lines += ["INVARIANTS"] + [f"  {i}" for i in INVARIANTS] + ["PROPERTY Steps", ""]
    open(f"{name}.cfg", "w").write("\n".join(lines))

# Looper

This is a looping music pad whose scheduler is redesigned as a small pure reconciler. The same design is checked three ways: TypeScript tests, TLA+, and Quint.

## Quick start

```sh
bun install
bun run dev        # playable demo at http://localhost:3000 (keys 1-8, q-i, a-d)
bun run check      # tsc, bun test, tla/check.sh, quint/check.sh  (about 20 s)
bun test
bun run typecheck
bun run build      # bundle index.html into dist/
```

## How it works

A press changes nothing immediately — it waits for the next 1-second grid tick, fades the old loop out, and fades the new one in at the right phase.  

The scheduler reconciles what you want with what's playing:

```
State  = { intent, voices, grid, nextId }
Voice  = { id, asset, startsAt, offset, fadeOut: Fade | null }
step(state, event) -> { state, commands }   // event = press | wake
nextWakeup(state, now) -> time | null       // one timer
```

- **Presses only change `intent`.** Nothing is scheduled or revoked.
- **One `settle` function changes audio.** It disposes finished fades, and if needed commits the next boundary at the right time.
- **Scheduled audio is immutable** except for gaining a fade-out.
- **Commands are a diff of `voices`** (`start`/`fadeOut`/`dispose`), driven by a single timer.
- **`lead` vs `decideAhead`:** `lead` is how far ahead we can schedule; `decideAhead` locks a boundary early with room for timer lateness.

## Properties

- `SingleTail`: at most one voice not fading
- `AtMostTwoVoices`: at most two voices at a time
- `GridExistsExactlyWhileSomethingIsAlive`: grid exists only while a voice exists
- `EveryVoiceIsOnTheGrid`: every voice starts on a tick at the grid's phase
- `NeverTwoLoopsAtFullVolume`: overlap only during fades
- `RespondsWithinBound`: after presses stop, hear intent within `decideAhead + tick + longFade`
- `NoVoiceIsCut`: voices removed only after fades finish
- `NothingIsScheduledTooLate`: starts/fades are at least `lead` in the future
- `ScheduledAudioIsImmutable`: only fade-outs can be added

## Verification

- **`bun test`** — runs scenario tests and 5,000 random sessions on real constants, checking all nine properties.
- **`tla/check.sh`** — runs TLC on every `tla/Looper*.cfg` and checks each result matches what's expected. One finding: a fade longer than two ticks needs a third voice, which breaks `AtMostTwoVoices`.
- **`quint/check.sh`** — runs `quint typecheck`, `quint test`, `quint run`, and `quint verify` (TLC backend), then `quint/mutations.py`.

Mutation testing: Quint's type checker rejects all 7 deliberate mistakes in `quint/mutations.py`. With `tla/mutations.py`, SANY accepts all 3 and TLC catches only 2; the third slips through silently.

**Layout (short):** `src/` (model/driver/synth/main), `test/` (model + properties), `tla/`, `quint/`, `index.html`.

## Requirements

- [Bun](https://bun.sh/)
- [TLA+ tools](https://lamport.azurewebsites.net/tla/tools.html) (`tlc`, `sany`) in `~/.local/bin` using `~/.local/share/tlaplus/tla2tools.jar`
- [Quint](https://github.com/informalsystems/quint) (`@informalsystems/quint` 0.33.1) globally
- `python3`
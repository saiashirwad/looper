# Looper

A standalone rebuild of the `AppPlaybackState` machine from `effect-garden/apps/next-midi-demo`. It is a redesign, not a port. The same design exists in three forms, and all three are checked against the same nine properties:

| Copy | Location | Checked by |
| --- | --- | --- |
| Implementation (pure model + driver) | `src/model.ts` (pure), `src/driver.ts` (Web Audio), `src/synth.ts`, `src/main.ts` | `bun test` (scenario tests and 5,000 random sessions on real constants) |
| TLA+ spec | `tla/Looper.tla` (+ generated configs/checks) | TLC (exhaustive), five configurations |
| Quint spec | `quint/looper.qnt` (+ checks/mutations) | `quint typecheck`, `quint test`, `quint run`, and `quint verify --backend tlc` |

## Quick start

```sh
bun install
bun run dev        # playable demo at http://localhost:3000 (keys 1-8, q-i, a-d)
bun run check      # tsc, bun test, tla/check.sh, quint/check.sh  (about 20 s)
bun test           # tests only
bun run typecheck  # tsc --noEmit
bun run build      # bundle index.html into dist/
```

`tlc` and `sany` are installed in `~/.local/bin` and use `~/.local/share/tlaplus/tla2tools.jar`. Quint is installed globally from npm (`@informalsystems/quint` 0.33.1).

## Project layout

```
src/model.ts        types, step, nextWakeup, diff         pure; the whole design
src/driver.ts       commands -> Web Audio, one timer      the only impure code
src/synth.ts        procedural stand-in loops for the demo
src/main.ts         keyboard and button UI
test/properties.ts  the nine properties as TypeScript functions
test/model.test.ts  scenarios and the 5,000-session random check
tla/                Looper.tla, gen-configs.py, check.sh, mutations.py
quint/              looper.qnt, check.sh, mutations.py
index.html          demo page
package.json        scripts and deps
```

## How it works

### The problem

A pad has 8 pattern buttons, 8 chord buttons and 3 strength buttons. Each combination is an 8-second loop. A press must not change the sound immediately: the change waits for the next 1-second grid tick, the old loop fades out, the new loop fades in at the right position inside its 8 seconds, and nothing clicks.

The original encodes this as 8 state classes with a fixed-shape queue of up to 3 elements. Audio is scheduled as soon as a press arrives; every later press must ask whether earlier schedules are "revocable" (leading to branches, including `Effect.die`), cleanup is a separate detached fiber per fade (disposing by position, correct only if queue order equals timer order), and nothing enforces that.

### The redesign

The scheduler is a reconciler between what the user wants and what is scheduled:

```
State  = { intent, voices, grid, nextId }
intent = { asset, playing }             what the user has selected
voices = Voice[]                        what the audio engine is doing
Voice  = { id, asset, startsAt, offset, fadeOut: Fade | null }
grid   = { anchor, decided } | null     exists exactly while a voice exists

step(state, event) -> { state, commands }   pure; event = press | wake, each carrying `at`
nextWakeup(state, now) -> time | null       pure; the driver's single timer
```

Key points:

1. **A press edits `intent` and nothing else.** It never touches audio. A press can never be "too late", and there is nothing to revoke.
2. **One function, `settle`, changes audio.** After every event: dispose voices whose fade has finished. If audio does not match intent and the next boundary has reached its decision time, decide that boundary (fade out current voice, start intended one there).
3. **Scheduled audio is immutable.** The only change a voice ever gets is gaining a fade-out. Changing your mind before the decision time costs no audio work; after it, the change goes to the next tick.
4. **Commands are a diff of `voices`.** `start`, `fadeOut`, and `dispose` are derived from before/after voice lists. The driver executes them and arms one timer for `nextWakeup`. No per-element fibers, no cleanup handles stored in state; disposal is by id.
5. **Two timing constants, not one.** `lead` (20 ms) is how far ahead the audio engine can be trusted to schedule. `decideAhead` (60 ms) is how early a boundary is locked in. The difference is the budget for a late `setTimeout`. (The original used a single constant for both roles.)

What this removes (vs original): 8 state classes/5 queue shapes/3 element classes → 1 state shape; "revocable or not" branches → none; 7 `Effect.die` branches → none (`step` is total); per-fade detached fibers disposing by position → one timer derived from state disposing by id; `chord`/`strength` stored separately able to drift → `intent` is the only selection; fade windows special-cased on loop boundaries → every fade starts on the boundary.

About 190 lines of pure model replace ~1,800 lines of `Machine/`, `Elements/`, the cleanup layer, and `timingsMath.ts`. Slow strums are out of scope (as in the original today) — they would be voices with fixed duration and an interrupting strum would reset `grid.anchor`.

Example: triple-tapping one pattern button (which kills the original) plays, stops, and plays again here (`test/model.test.ts`), covering taps just before, at, and just after the decision time.

### The properties

All three copies check these nine properties:

- `SingleTail`: at most one voice is not fading.
- `AtMostTwoVoices`: at most two voices exist at any time.
- `GridExistsExactlyWhileSomethingIsAlive`: the grid exists exactly while a voice exists.
- `EveryVoiceIsOnTheGrid`: every voice starts on a tick, at the loop offset the grid implies.
- `NeverTwoLoopsAtFullVolume`: two loops overlap only inside a fade.
- `RespondsWithinBound`: once presses stop, within `decideAhead + tick + longFade` you hear exactly the intent.
- `NoVoiceIsCut`: a voice is removed only after its fade-out has ended (no-clicks property).
- `NothingIsScheduledTooLate`: every start and every fade is at least `lead` in the future.
- `ScheduledAudioIsImmutable`: a live voice's only possible change is gaining a fade-out.

## Verification

### Tests (TypeScript/Bun)

- `bun test` runs `test/model.test.ts` and uses `test/properties.ts` (the same nine properties as TS functions). Includes scenario tests and a property check: **5,000 random sessions** on the real constants with timer lateness up to `decideAhead - lead`. Negative tests verify the checks have teeth (excessive lateness or long fades break the expected properties).
- `bun run typecheck` runs `tsc --noEmit`.

### TLA+

- Specs/configs in `tla/` (`Looper.tla`, `gen-configs.py`, `check.sh`, `mutations.py`).
- `tla/check.sh` generates configs with `gen-configs.py` and runs TLC on every `Looper*.cfg`, comparing outcomes to `EXPECT:` lines.
- Notable cases: `Looper.timer-starves.cfg` reproduces timer starvation with one constant; `Looper.late-timer.cfg` shows lateness within budget is fine; `Looper.bound-is-tight.cfg` shows the response bound is tight; `Looper.long-fade.cfg` sets `LongFade` just over two ticks and finds play/stop/play/switch with three voices alive, which breaks `AtMostTwoVoices`; every other property still holds. Because `voices` is a list, only the resource bound changes and no state class needs to be added.
- State space (typical): ~152,670 distinct states with 3 presses (~1s); ~952,062 states with 4 presses, 24 time units, late timer (~4s).
- `tla/mutations.py` introduces three mistakes; SANY accepts all three, TLC catches two at runtime, but the third (comparing pattern to integer) evaluates as false silently and all invariants still pass.

### Quint

- Spec in `quint/looper.qnt` with scenario tests in module `defaults` and a `longFade` instance.
- `quint/check.sh` does: `quint typecheck`, `quint test` (scenario tests), `quint run` (10,000 random traces on defaults), `quint verify` with TLC backend on `defaults` (expected pass) and on `longFade` (expected fail), then runs `quint/mutations.py`.
- Quint catches all seven mutations via the type checker (vs TLA+/SANY missing the integer-vs-pattern comparison). Step properties are written as invariants over `before`/`m` (Quint needs a `before` variable). Constants are passed via module instantiation.
- Exhaustive (TLC backend) on defaults gave ~254,207 states in this repo’s measurements; symbolic checking with Apalache was too slow here (depth 7/12 after ~8 min).

### Notes on TLA+ vs Quint (from the project)

| Aspect | TLA+ (TLC 2.19) | Quint 0.33.1 |
| --- | --- | --- |
| Optional values | sets used as options + booleans/zeroed fields | `Option[...]`, `match` |
| Press kinds | records with string `kind` | ADTs (`PatternPress`/`VariantPress`) |
| Missing `match`/branch | not caught as error; `IF` without `ELSE` behaves differently | type checker rejects |
| Type errors | often found only if TLC evaluates the expression | caught before running |
| Pure vs stateful | same syntax | `pure def` cannot read state; `action` cannot sit in pure function |
| Scenario tests | none built in | `run ...Test` + `quint test` |
| Random simulation | `tlc -simulate` | `quint run` (10k traces ~3s) |
| Exhaustive check | TLC directly | same TLC via `--backend tlc` |
| Symbolic (Apalache) | n/a | too slow on this spec |
| Step properties | `[][A]_vars` directly on action formulas | need `before` variable to write as invariants |
| Constants per run | per `.cfg` (generated) | per instance (`import looper(...)`) |
| Traces | name actions taken | show states only |

Recommendation from the project: learn Quint first (types catch common mistakes early; `quint test` gives a vitest-like loop). Run exhaustive checks via `quint verify --backend tlc`. Read TLA+ when needed (Quint compiles to TLA+).

## Requirements

- [Bun](https://bun.sh/) for running/building/tests
- For full verification: [TLA+ tools](https://lamport.azurewebsites.net/tla/tools.html) (`tlc`, `sany`) available as above (or adjust paths in scripts)
- [Quint](https://github.com/informalsystems/quint) installed globally (`@informalsystems/quint` 0.33.1)
- `python3` for `tla/gen-configs.py` and mutation scripts

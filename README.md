# Looper: the playback scheduler, redesigned

This is a standalone rebuild of the `AppPlaybackState` machine from
`effect-garden/apps/next-midi-demo`. It is a redesign, not a port. The same design
exists three times, and each copy is checked against the same nine properties:

| Copy | File | Checked by |
| --- | --- | --- |
| Implementation | `src/model.ts` (pure), `src/driver.ts` (Web Audio) | `bun test`: scenario tests and 5,000 random sessions on the real constants |
| TLA+ spec | `tla/Looper.tla` | TLC, exhaustive, five configurations |
| Quint spec | `quint/looper.qnt` | the Quint type checker, `quint test`, `quint run`, and TLC through `quint verify --backend tlc` |

```sh
bun install
bun run check     # tsc, bun test, tla/check.sh, quint/check.sh  (about 20 s)
bun run dev       # the playable demo at http://localhost:3000 (keys 1-8, q-i, a-d)
```

`tlc` and `sany` are installed in `~/.local/bin` and use
`~/.local/share/tlaplus/tla2tools.jar`. Quint is installed globally from npm
(`@informalsystems/quint` 0.33.1).

## The problem

A pad has 8 pattern buttons, 8 chord buttons and 3 strength buttons. Each
combination is an 8-second loop. A press must not change the sound immediately.
The change waits for the next 1-second grid tick, the old loop fades out, the new
loop fades in at the right position inside its 8 seconds, and nothing clicks.

The original encodes this as 8 state classes (`PatternPatternTransitionState`,
`PatternSilencePatternTransitionState`, and so on), each with a fixed-shape queue
of up to 3 elements. It schedules audio as soon as a press arrives. Because of
that, every later press has to ask whether the earlier schedule "is still
revocable", and then cancel, restore or promote it. Each answer is a branch, and
7 of those branches are `Effect.die`. Cleanup is a separate detached fiber per
fade, which disposes `transitionQueue[0]` by position, so it is correct only if
queue order equals timer order. Nothing enforces that.

## The redesign

The scheduler is a reconciler between what the user wants and what is scheduled.

```
State  = { intent, voices, grid, nextId }
intent = { asset, playing }             what the user has selected
voices = Voice[]                        what the audio engine is doing
Voice  = { id, asset, startsAt, offset, fadeOut: Fade | null }
grid   = { anchor, decided } | null     exists exactly while a voice exists

step(state, event) -> { state, commands }   pure; event = press | wake, each carrying `at`
nextWakeup(state, now) -> time | null       pure; the driver's single timer
```

1. **A press edits `intent` and nothing else.** It never touches audio. A press
   can therefore never be "too late", and there is nothing to revoke.
2. **One function, `settle`, changes audio.** It runs after every event. It
   disposes voices whose fade has finished. Then, if the audio does not match the
   intent and the next boundary has reached its decision time, it decides that
   boundary: it fades out the current voice and starts the intended one there.
3. **Scheduled audio is immutable.** The only change a voice ever gets is a
   fade-out. Changing your mind before the decision time costs no audio work.
   After it, the change goes to the next tick.
4. **Commands are a diff of `voices`.** `start`, `fadeOut` and `dispose` are
   derived from the before and after voice lists. The driver executes them and
   arms one timer for `nextWakeup`. There are no per-element fibers and no
   cleanup handles stored in state. Disposal is by id.
5. **Two timing constants, not one.** `lead` (20 ms) is how far ahead the audio
   engine can be trusted to schedule. `decideAhead` (60 ms) is how early a
   boundary is locked in. The difference is the budget for a late `setTimeout`.
   The original has one constant, `schedulingSafeBufferInSeconds`, for both
   roles. TLC showed why they must be separate (see below).

What this removes compared with the original:

| Original | Here |
| --- | --- |
| 8 state classes, 5 queue shapes, 3 element classes | 1 state shape |
| "revocable or not" branches in every transition | none, because nothing is scheduled early |
| 7 `Effect.die` branches | none; `step` is total |
| one detached cleanup fiber per fade, disposing by position | one timer derived from state, disposing by id |
| `chord` and `strength` stored beside the queue, and able to drift | `intent` is the only selection |
| fade windows special-cased on loop boundaries | every fade starts on the boundary |

About 190 lines of pure model replace about 1,800 lines of `Machine/`,
`Elements/`, the cleanup layer and `timingsMath.ts`. Slow strums are out of
scope, as they are in the original today. They would be voices with a fixed
duration, and an interrupting strum would reset `grid.anchor`.

Three-tapping one pattern button, which kills the original, plays, stops and
plays again here (`test/model.test.ts`). The test covers taps just before, at,
and just after the decision time.

## The properties

All three copies check these nine:

- `SingleTail`: at most one voice is not fading.
- `AtMostTwoVoices`: at most two voices exist at any time.
- `GridExistsExactlyWhileSomethingIsAlive`: the grid exists exactly while a voice exists.
- `EveryVoiceIsOnTheGrid`: every voice starts on a tick, at the loop offset the grid implies.
- `NeverTwoLoopsAtFullVolume`: two loops overlap only inside a fade.
- `RespondsWithinBound`: once presses stop, within `decideAhead + tick + longFade` you hear exactly the intent.
- `NoVoiceIsCut`: a voice is removed only after its fade-out has ended. This is the no-clicks property.
- `NothingIsScheduledTooLate`: every start and every fade is at least `lead` in the future.
- `ScheduledAudioIsImmutable`: a live voice's only possible change is gaining a fade-out.

## What TLC found while designing this

The first two findings were mistakes in my own first draft. That is the job TLA+
did best here: it checked a design before any of it was code.

1. **A stale `decided` caused early commits.** In the first draft, an idle
   machine never advanced `decided`. A press that came after the idle machine's
   old deadline was committed immediately, for a boundary a whole tick away, and
   the user lost the chance to change their mind. `RespondsWithinBound` failed
   with a 17-step trace. The fix was to compute the target boundary from `now`.
2. **Timer lateness starves the machine.** With one constant playing both
   roles, a wakeup that fires late misses its boundary. The next wakeup is late
   again and misses the next boundary, forever. `Looper.timer-starves.cfg`
   reproduces this. Splitting the constant into `lead` and `decideAhead` fixes
   it, and `Looper.late-timer.cfg` proves lateness within the budget costs
   nothing.
3. **The response bound is tight.** `Looper.bound-is-tight.cfg` shortens the
   bound by one unit, and TLC produces a trace that needs the full bound.
4. **A longer fade-to-silence needs a third voice.** The original has a comment
   saying `fadeToSilenceTimeInSeconds` "will likely grow, possibly to multiple
   ticks". `Looper.long-fade.cfg` sets it to just over two ticks. TLC finds
   play, stop, play, switch, with three voices alive at once. Every other
   property still holds. Because `voices` is a list rather than a fixed tuple,
   only the resource bound changes and no state class needs to be added.

The TLA+ state space is 152,670 distinct states with 3 presses (about 1 second).
With 4 presses, 24 time units and a late timer it is 952,062 states (about 4
seconds).

## Quint compared with TLA+, on this spec

The Quint spec is the same design written in Quint's own idioms. Every claim in
this table was measured on this repo.

| | TLA+ (TLC 2.19) | Quint 0.33.1 |
| --- | --- | --- |
| Optional values | a set used as an option (`grid = {}`, `CHOOSE g \in grid`) and a `fading` boolean next to zeroed fields | `Option[Grid]`, `Option[Fade]`, and `match` |
| Press kinds | records with a string `kind` | `PatternPress(Pattern) \| VariantPress(Variant)` |
| A missing `match` case | not expressible; an `IF` with no `ELSE` arm is just different behavior | rejected by the type checker |
| Type errors | found only when TLC evaluates the expression, if it ever does | rejected before anything runs |
| Pure vs. stateful code | the same operator syntax for both | `pure def` cannot read state, and an `action` cannot sit inside a pure function |
| Scenario tests | none built in | `run ...Test` plus `quint test` |
| Random simulation | `tlc -simulate` | `quint run`, 10,000 traces in about 3 seconds |
| Exhaustive check | TLC directly | the same TLC through `--backend tlc`, 254,207 states |
| Symbolic check (Apalache) | n/a | too slow here: depth 7 of 12 after 8 minutes, then I stopped it |
| Step properties | `[][A]_vars` checks action formulas directly | needs a `before` variable so they can be written as invariants |
| Constants per run | one `.cfg` file each, generated by `tla/gen-configs.py` | one `import looper(Tick = 4, ...)` module each, in the same file |
| Traces | name the action taken | show states only |

`quint/mutations.py` makes seven typical mistakes in the Quint spec, and the type
checker rejects all seven. `tla/mutations.py` makes three of the same kinds of
mistake in the TLA+ spec. SANY accepts all three. TLC catches two of them at run
time. The third compares a pattern with an integer. TLC evaluates that
comparison as false and reports no error. The broken spec silently means
"pressing the playing pattern never stops it", and every invariant still
passes. Quint rejects the same mistake before anything runs.

Recommendation for Eva: learn Quint first. The type system catches the mistakes a
beginner makes most often, before they turn into confusing model-checker
results. `quint test` provides the unit-test loop she already uses in vitest.
Run exhaustive checks through `--backend tlc`. Read TLA+ when a resource only
explains things in TLA+. That is easy, because Quint compiles to it.

## Layout

```
src/model.ts        types, step, nextWakeup, diff         pure; the whole design
src/driver.ts       commands -> Web Audio, one timer      the only impure code
src/synth.ts        procedural stand-in loops for the demo
src/main.ts         keyboard and button UI
test/properties.ts  the nine properties as TypeScript functions
test/model.test.ts  scenarios and the 5,000-session random check
tla/                Looper.tla, gen-configs.py, check.sh, mutations.py
quint/              looper.qnt, check.sh, mutations.py
```

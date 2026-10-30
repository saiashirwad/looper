// The loop scheduler as a desired-state reconciler. Same design as
// ../tla/Looper.tla and ../src/model.ts; see ../README.md.
module looper {
  // ---------------------------------------------------------------------------
  // Parameters. Instances at the bottom of the file pick the values.
  const Tick: int         // grid spacing: changes land on multiples of Tick from the anchor
  const Loop: int         // length of every loop, a multiple of Tick
  const Lead: int         // the least distance into the future the audio engine can schedule
  const DecideAhead: int  // how early a boundary is locked in; DecideAhead - Lead absorbs timer lateness
  const Crossfade: int    // fade used between two patterns
  const LongFade: int     // fade used when stopping into silence
  const MaxLate: int      // how late the wakeup timer may fire
  const MaxTime: int      // bound on the clock, for model checking only
  const MaxPresses: int   // bound on presses, for model checking only

  assume orderings = and {
    Tick > DecideAhead, DecideAhead >= Lead, Lead > 0,
    Crossfade > 0, LongFade > 0,
    Loop >= Tick, Loop % Tick == 0,
    MaxLate >= 0, MaxLate < Tick - DecideAhead,
  }

  // ---------------------------------------------------------------------------
  // Domain
  type Option[a] = Some(a) | None

  type Pattern = P1 | P2 | P3
  type Variant = V1 | V2  // one "set" dimension; chord and strength behave identically

  type Asset = { pattern: Pattern, variant: Variant }
  type Intent = { asset: Asset, playing: bool }
  type Fade = { from: int, until: int }
  type Voice = { id: int, asset: Asset, startsAt: int, offset: int, fadeOut: Option[Fade] }
  type Grid = { anchor: int, decided: int }
  type Machine = { intent: Intent, voices: Set[Voice], grid: Option[Grid], nextId: int }

  type Press = PatternPress(Pattern) | VariantPress(Variant)

  pure val Patterns = Set(P1, P2, P3)
  pure val Variants = Set(V1, V2)
  pure val AllPresses = Patterns.map(p => PatternPress(p)).union(Variants.map(v => VariantPress(v)))

  pure val InitialMachine: Machine = {
    intent: { asset: { pattern: P1, variant: V1 }, playing: false },
    voices: Set(),
    grid: None,
    nextId: 1,
  }

  // ---------------------------------------------------------------------------
  // Reading a machine
  pure def min(s: Set[int]): Option[int] =
    s.fold(None, (acc, x) => match acc { | None => Some(x) | Some(y) => Some(if (x < y) x else y) })

  pure def isFading(v: Voice): bool = v.fadeOut != None

  // Has the voice's fade-out begun / finished by time t? Both false while it is not fading.
  pure def fadeStartedBy(v: Voice, t: int): bool = match v.fadeOut { | Some(f) => f.from <= t | None => false }
  pure def fadeDoneBy(v: Voice, t: int): bool = match v.fadeOut { | Some(f) => f.until <= t | None => false }

  // The voice that is not fading out, if any. At most one (singleTail).
  pure def tailOf(s: Machine): Set[Voice] = s.voices.filter(v => not(isFading(v)))

  pure def audioMatchesIntent(s: Machine): bool =
    if (s.intent.playing) tailOf(s).exists(v => v.asset == s.intent.asset)
    else tailOf(s) == Set()

  pure def fadeEnds(s: Machine): Set[int] =
    s.voices.map(v => match v.fadeOut { | Some(f) => Set(f.until) | None => Set() }).flatten()

  // ---------------------------------------------------------------------------
  // The reducer
  pure def applyPress(intent: Intent, p: Press): Intent = match p {
    | PatternPress(pattern) =>
        if (intent.playing and intent.asset.pattern == pattern) { ...intent, playing: false }
        else { playing: true, asset: { ...intent.asset, pattern: pattern } }
    | VariantPress(v) => { ...intent, asset: { ...intent.asset, variant: v } }
  }

  // The earliest boundary after `decided` that can still be scheduled at t. A wakeup
  // later than DecideAhead - Lead skips to the next boundary instead of scheduling into the past.
  pure def target(grid: Option[Grid], t: int): int = match grid {
    | None => t + Lead
    | Some(g) =>
        val first = g.decided + Tick
        if (first >= t + Lead) first
        else first + ((t + Lead - first + Tick - 1) / Tick) * Tick
  }

  pure def dispose(s: Machine, t: int): Machine =
    val kept = s.voices.filter(v => not(fadeDoneBy(v, t)))
    { ...s, voices: kept, grid: if (kept == Set()) None else s.grid }

  pure def commitDue(s: Machine, t: int): bool = and {
    not(audioMatchesIntent(s)),
    match s.grid { | None => true | Some(_) => t >= target(s.grid, t) - DecideAhead },
  }

  pure def commit(s: Machine, t: int): Machine =
    val at = target(s.grid, t)
    val anchor = match s.grid { | None => at | Some(g) => g.anchor }
    val fadeLength = if (s.intent.playing) Crossfade else LongFade
    val faded = s.voices.map(v =>
      if (isFading(v)) v else { ...v, fadeOut: Some({ from: at, until: at + fadeLength }) })
    val fresh: Voice = {
      id: s.nextId, asset: s.intent.asset, startsAt: at, offset: (at - anchor) % Loop, fadeOut: None,
    }
    {
      ...s,
      voices: if (s.intent.playing) faded.union(Set(fresh)) else faded,
      grid: Some({ anchor: anchor, decided: at }),
      nextId: s.nextId + 1,
    }

  pure def settle(s: Machine, t: int): Machine =
    val d = dispose(s, t)
    if (commitDue(d, t)) commit(d, t) else d

  // Every time at which settle has something to do. The driver keeps exactly one timer,
  // armed for the earliest of these after each event.
  pure def wakeups(s: Machine, t: int): Set[int] =
    val deadline = if (not(audioMatchesIntent(s)) and s.grid != None) Set(target(s.grid, t) - DecideAhead) else Set()
    fadeEnds(s).union(deadline)

  // ---------------------------------------------------------------------------
  // The environment: a user, a clock, and a timer that may be late
  var m: Machine
  var now: int           // audio clock
  var alarm: Option[int] // the driver's one armed timer
  var presses: int       // presses so far (bound only)
  var lastPressAt: int   // observer for respondsWithinBound; -1 before any press
  // The machine before the last step, so step properties can be plain invariants.
  var before: Machine
  var beforeNow: int

  action init = all {
    m' = InitialMachine, before' = InitialMachine,
    now' = 0, beforeNow' = 0, alarm' = None, presses' = 0, lastPressAt' = -1,
  }

  // The machine moves to `after` and the timer is re-armed; the clock stands still.
  action react(after: Machine): bool = all {
    m' = after, before' = m, beforeNow' = now, alarm' = min(wakeups(after, now)), now' = now,
  }

  action userPresses(p: Press): bool = all {
    presses < MaxPresses,
    react(settle({ ...m, intent: applyPress(m.intent, p) }, now)),
    presses' = presses + 1,
    lastPressAt' = now,
  }

  action timerFires = all {
    match alarm { | Some(a) => now >= a | None => false },
    react(settle(m, now)),
    presses' = presses,
    lastPressAt' = lastPressAt,
  }

  // Only the clock may change; everything else stays as it is.
  action clockMovesTo(t: int): bool = all {
    now' = t,
    m' = m, before' = m, beforeNow' = now,
    alarm' = alarm, presses' = presses, lastPressAt' = lastPressAt,
  }

  action timePasses = all {
    now < MaxTime,
    match alarm { | Some(a) => now < a + MaxLate | None => true },
    clockMovesTo(now + 1),
  }

  action endOfCheckedTime = all {
    now == MaxTime,
    clockMovesTo(now),
  }

  action step = any {
    nondet p = AllPresses.oneOf()
    userPresses(p),
    timerFires,
    timePasses,
    endOfCheckedTime,
  }

  // ---------------------------------------------------------------------------
  // What the listener hears
  pure def soundingAt(s: Machine, t: int): Set[Voice] =
    s.voices.filter(v => v.startsAt <= t and not(fadeDoneBy(v, t)))

  pure def atFullVolume(s: Machine, t: int): Set[Voice] =
    s.voices.filter(v => v.startsAt + Crossfade <= t and not(fadeStartedBy(v, t)))

  pure def hearsTheIntent(s: Machine, t: int): bool =
    val heard = soundingAt(s, t)
    if (s.intent.playing)
      heard.size() == 1 and heard.forall(v => not(isFading(v)) and v.asset == s.intent.asset)
    else
      heard == Set()

  // ---------------------------------------------------------------------------
  // Invariants: true in every reachable state
  val singleTail = tailOf(m).size() <= 1
  val atMostTwoVoices = m.voices.size() <= 2
  val gridExistsExactlyWhileSomethingIsAlive = (m.grid == None) iff (m.voices == Set())

  // Every voice starts on the grid, at the loop position the grid implies, so all
  // loops stay phase-locked to the first one.
  val everyVoiceIsOnTheGrid = match m.grid {
    | None => true
    | Some(g) => m.voices.forall(v => {
        val sinceAnchor = v.startsAt - g.anchor
        sinceAnchor % Tick == 0 and v.offset == sinceAnchor % Loop
      })
  }

  // Two loops are never both at full volume; overlap only happens inside a fade.
  val neverTwoLoopsAtFullVolume = atFullVolume(m, now).size() <= 1

  // Stop pressing, and within a fixed time you hear exactly what you selected: a press just
  // after a boundary was locked waits one tick for the next one, then the fade has to finish.
  pure val ResponseBound = DecideAhead + Tick + LongFade
  val respondsWithinBound =
    (lastPressAt >= 0 and now >= lastPressAt + ResponseBound) implies hearsTheIntent(m, now)

  // ---------------------------------------------------------------------------
  // Step properties: true of every transition, written over (before, m)
  pure def ids(vs: Set[Voice]): Set[int] = vs.map(v => v.id)

  // A voice is only ever removed after its fade-out has finished: no clicks.
  val noVoiceIsCut = before.voices.forall(v =>
    not(ids(m.voices).contains(v.id)) implies fadeDoneBy(v, beforeNow))

  // Everything newly scheduled, start or fade, is at least Lead in the future.
  val nothingIsScheduledTooLate = m.voices.forall(v =>
    if (not(ids(before.voices).contains(v.id)))
      v.startsAt >= beforeNow + Lead
    else
      before.voices.forall(old => (old.id == v.id and not(isFading(old))) implies match v.fadeOut {
        | None => true
        | Some(f) => f.from >= beforeNow + Lead
      }))

  // Scheduled audio is never rewritten. The only change a live voice may see is
  // gaining a fade-out it did not have.
  val scheduledAudioIsImmutable = m.voices.forall(v => before.voices.forall(old =>
    old.id == v.id implies (v == old or (not(isFading(old)) and { ...v, fadeOut: None } == old))))

  val safety = and {
    singleTail, atMostTwoVoices, gridExistsExactlyWhileSomethingIsAlive, everyVoiceIsOnTheGrid,
    neverTwoLoopsAtFullVolume, respondsWithinBound,
    noVoiceIsCut, nothingIsScheduledTooLate, scheduledAudioIsImmutable,
  }
}

module defaults {
  import looper(
    Tick = 4, Loop = 8, Lead = 1, DecideAhead = 2, Crossfade = 1, LongFade = 2,
    MaxLate = 1, MaxTime = 20, MaxPresses = 3,
  ).*

  // ---------------------------------------------------------------------------
  // Scenario tests: `quint test`
  run tripleTapNeverDiesTest = init
    .then(userPresses(PatternPress(P1)))
    .then(userPresses(PatternPress(P1)))
    .then(userPresses(PatternPress(P1)))
    .then(all { assert(m.intent.playing), timePasses })
    .then(all { assert(safety), timePasses })

  run changingYourMindCostsNothingTest = init
    .then(userPresses(PatternPress(P1)))
    .then(timePasses)
    .then(userPresses(PatternPress(P2)))
    .then(userPresses(PatternPress(P1)))
    .then(all { assert(m.voices.size() == 1 and alarm == None), timePasses })
}

module longFade {
  import looper(
    Tick = 4, Loop = 8, Lead = 1, DecideAhead = 2, Crossfade = 1, LongFade = 9,
    MaxLate = 0, MaxTime = 24, MaxPresses = 4,
  ).*
}

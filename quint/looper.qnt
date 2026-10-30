// The loop scheduler as a desired-state reconciler. Same design as
// ../tla/Looper.tla and ../src/model.ts; see ../README.md.
module looper {
  // ---------------------------------------------------------------------------
  // Parameters. Instances at the bottom of the file pick the values.
  const Tick: int
  const Loop: int
  const Lead: int
  const DecideAhead: int
  const Crossfade: int
  const LongFade: int
  const MaxLate: int
  const MaxTime: int
  const MaxPresses: int

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
  type Variant = V1 | V2

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

  // The earliest boundary after `decided` that can still be scheduled at t.
  pure def target(grid: Option[Grid], t: int): int = match grid {
    | None => t + Lead
    | Some(g) =>
        val first = g.decided + Tick
        if (first >= t + Lead) first
        else first + ((t + Lead - first + Tick - 1) / Tick) * Tick
  }

  pure def dispose(s: Machine, t: int): Machine =
    val kept = s.voices.filter(v => match v.fadeOut { | Some(f) => f.until > t | None => true })
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

  pure def wakeups(s: Machine, t: int): Set[int] =
    fadeEnds(s).union(
      if (not(audioMatchesIntent(s)) and s.grid != None) Set(target(s.grid, t) - DecideAhead) else Set())

  // ---------------------------------------------------------------------------
  // The environment
  var m: Machine
  var now: int
  var alarm: Option[int]
  var presses: int
  var lastPressAt: int
  // The machine before the last step, so step properties can be plain invariants.
  var before: Machine
  var beforeNow: int

  action init = all {
    m' = InitialMachine, before' = InitialMachine,
    now' = 0, beforeNow' = 0, alarm' = None, presses' = 0, lastPressAt' = -1,
  }

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

  action timePasses = all {
    now < MaxTime,
    match alarm { | Some(a) => now < a + MaxLate | None => true },
    now' = now + 1,
    m' = m, before' = m, beforeNow' = now,
    alarm' = alarm, presses' = presses, lastPressAt' = lastPressAt,
  }

  action endOfCheckedTime = all {
    now == MaxTime,
    m' = m, before' = m, beforeNow' = now,
    now' = now, alarm' = alarm, presses' = presses, lastPressAt' = lastPressAt,
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
    s.voices.filter(v => v.startsAt <= t and match v.fadeOut { | None => true | Some(f) => t < f.until })

  pure def atFullVolume(s: Machine, t: int): Set[Voice] =
    s.voices.filter(v => v.startsAt + Crossfade <= t and match v.fadeOut { | None => true | Some(f) => t < f.from })

  pure def hearsTheIntent(s: Machine, t: int): bool =
    val heard = soundingAt(s, t)
    if (s.intent.playing) heard.size() == 1 and heard.forall(v => not(isFading(v)) and v.asset == s.intent.asset)
    else heard == Set()

  // ---------------------------------------------------------------------------
  // Invariants
  val singleTail = tailOf(m).size() <= 1
  val atMostTwoVoices = m.voices.size() <= 2
  val gridExistsExactlyWhileSomethingIsAlive = (m.grid == None) iff (m.voices == Set())
  val everyVoiceIsOnTheGrid = match m.grid {
    | None => true
    | Some(g) => m.voices.forall(v => (v.startsAt - g.anchor) % Tick == 0 and v.offset == (v.startsAt - g.anchor) % Loop)
  }
  val neverTwoLoopsAtFullVolume = atFullVolume(m, now).size() <= 1

  pure val ResponseBound = DecideAhead + Tick + LongFade
  val respondsWithinBound = (lastPressAt >= 0 and now >= lastPressAt + ResponseBound) implies hearsTheIntent(m, now)

  // Step properties, over (before, m)
  pure def ids(vs: Set[Voice]): Set[int] = vs.map(v => v.id)

  val noVoiceIsCut = before.voices.forall(v =>
    not(ids(m.voices).contains(v.id)) implies match v.fadeOut { | None => false | Some(f) => f.until <= beforeNow })

  val nothingIsScheduledTooLate = m.voices.forall(v =>
    if (not(ids(before.voices).contains(v.id))) v.startsAt >= beforeNow + Lead
    else before.voices.forall(old => (old.id == v.id and not(isFading(old))) implies match v.fadeOut {
      | None => true
      | Some(f) => f.from >= beforeNow + Lead
    }))

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

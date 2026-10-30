------------------------------- MODULE Looper -------------------------------
(*
  The loop scheduler as a desired-state reconciler.

  A press only edits `intent`. It never touches audio. Audio is a set of
  `voices`, and the only thing that changes them is `Settle`, which runs after
  every event. Settle does two things, in this order:

    1. dispose every voice whose fade-out has finished
    2. if the audio does not match the intent yet and the next grid boundary
       has reached its scheduling deadline, decide that boundary: fade out
       whatever is playing and start the intended asset there

  Nothing scheduled is ever revoked, so there is nothing to cancel, and no
  branch depends on whether a fade "is still revocable". A press that arrives
  before a boundary's deadline is simply part of the intent when the boundary
  gets decided.

  Time is an integer clock in abstract units. The defaults keep the orderings
  of the real constants (lead << tick, fades shorter than a tick, a loop of
  several ticks) at a size TLC can enumerate. The timer that drives Settle may
  fire up to MaxLate units late.

  This spec and src/model.ts are the same design. It is not a translation of
  either one into the other: both are checked against the same properties.
*)
EXTENDS Integers, FiniteSets

CONSTANTS
  Patterns,      \* pattern buttons
  Variants,      \* one "set" dimension; chord and strength behave identically
  Tick,          \* grid spacing: changes land on multiples of Tick from the anchor
  Loop,          \* length of every loop, a multiple of Tick
  Lead,          \* the least distance into the future the audio engine can schedule
  DecideAhead,   \* how early a boundary is locked in; DecideAhead - Lead absorbs timer lateness
  Crossfade,     \* fade used between two patterns
  LongFade,      \* fade used when stopping into silence
  MaxLate,       \* how late the wakeup timer may fire
  MaxTime,       \* bound on the clock, for model checking only
  MaxPresses,    \* bound on presses, for model checking only
  ShortenBoundBy \* 0 in the passing run; 1 asks TLC whether the bound is tight

ASSUME /\ Tick > DecideAhead /\ DecideAhead >= Lead /\ Lead > 0
       /\ Crossfade > 0 /\ LongFade > 0
       /\ Loop >= Tick /\ Loop % Tick = 0
       /\ MaxLate >= 0 /\ MaxLate < Tick - DecideAhead

Asset == [pattern : Patterns, variant : Variants]
Press == [kind : {"pattern"}, value : Patterns] \cup [kind : {"variant"}, value : Variants]

InitialAsset == [pattern |-> CHOOSE p \in Patterns : TRUE,
                 variant |-> CHOOSE v \in Variants : TRUE]

Min(S) == CHOOSE x \in S : \A y \in S : x <= y

VARIABLES
  m,            \* the machine: [intent, voices, grid, nextId]
  now,          \* audio clock
  alarm,        \* the driver's one armed timer: {} or {t}
  presses,      \* presses so far (bound only)
  lastPressAt   \* observer for the response-time property; -1 before any press

vars == <<m, now, alarm, presses, lastPressAt>>

-----------------------------------------------------------------------------
(* Reading a machine state *)

\* `grid` is an option: {} while silent, otherwise one [anchor, decided] record.
\* `decided` is the last boundary whose audio is fixed.
G(s) == CHOOSE g \in s.grid : TRUE

\* The voice that is not fading out, if any. At most one (SingleTail).
Tail(s) == {v \in s.voices : ~v.fading}

AudioMatchesIntent(s) ==
  IF s.intent.playing
    THEN \E v \in Tail(s) : v.asset = s.intent.asset
    ELSE Tail(s) = {}

\* The earliest boundary after `decided` that can still be scheduled at time t.
\* A wakeup later than DecideAhead - Lead skips to the next boundary instead of
\* scheduling into the past.
Target(s, t) ==
  IF s.grid = {} THEN t + Lead
  ELSE LET f == G(s).decided + Tick
       IN IF f >= t + Lead THEN f
          ELSE f + ((t + Lead - f + Tick - 1) \div Tick) * Tick

\* Every time at which Settle has something to do. The driver keeps exactly one
\* timer, armed for the earliest of these after each event. It is a function of
\* the state, so no timer can belong to an element that no longer exists.
Wakeups(s, t) ==
  {v.fadeEnd : v \in {w \in s.voices : w.fading}}
  \cup (IF ~AudioMatchesIntent(s) /\ s.grid # {} THEN {Target(s, t) - DecideAhead} ELSE {})

Alarm(s, t) == IF Wakeups(s, t) = {} THEN {} ELSE {Min(Wakeups(s, t))}

-----------------------------------------------------------------------------
(* The reducer *)

ApplyPress(s, p) ==
  IF p.kind = "pattern"
    THEN IF s.intent.playing /\ s.intent.asset.pattern = p.value
           THEN [s EXCEPT !.intent.playing = FALSE]
           ELSE [s EXCEPT !.intent = [playing |-> TRUE,
                                      asset |-> [s.intent.asset EXCEPT !.pattern = p.value]]]
    ELSE [s EXCEPT !.intent.asset.variant = p.value]

Dispose(s, t) ==
  LET kept == {v \in s.voices : ~(v.fading /\ v.fadeEnd <= t)}
  IN [s EXCEPT !.voices = kept, !.grid = IF kept = {} THEN {} ELSE s.grid]

CommitDue(s, t) ==
  /\ ~AudioMatchesIntent(s)
  /\ IF s.grid = {} THEN TRUE ELSE t >= Target(s, t) - DecideAhead

Commit(s, t) ==
  LET b       == Target(s, t)
      anchor  == IF s.grid = {} THEN b ELSE G(s).anchor
      fadeLen == IF s.intent.playing THEN Crossfade ELSE LongFade
      faded   == {IF v.fading THEN v
                  ELSE [v EXCEPT !.fading = TRUE, !.fadeStart = b, !.fadeEnd = b + fadeLen]
                  : v \in s.voices}
      fresh   == [id |-> s.nextId, asset |-> s.intent.asset,
                  startsAt |-> b, offset |-> (b - anchor) % Loop,
                  fading |-> FALSE, fadeStart |-> 0, fadeEnd |-> 0]
  IN [s EXCEPT !.voices = IF s.intent.playing THEN faded \cup {fresh} ELSE faded,
               !.grid   = {[anchor |-> anchor, decided |-> b]},
               !.nextId = s.nextId + 1]

Settle(s, t) ==
  LET d == Dispose(s, t) IN IF CommitDue(d, t) THEN Commit(d, t) ELSE d

-----------------------------------------------------------------------------
(* The environment: a user, a clock, and a timer that may be late *)

Init ==
  /\ m = [intent |-> [playing |-> FALSE, asset |-> InitialAsset],
          voices |-> {}, grid |-> {}, nextId |-> 1]
  /\ now = 0
  /\ alarm = {}
  /\ presses = 0
  /\ lastPressAt = -1

UserPresses(p) ==
  /\ presses < MaxPresses
  /\ m' = Settle(ApplyPress(m, p), now)
  /\ alarm' = Alarm(m', now)
  /\ presses' = presses + 1
  /\ lastPressAt' = now
  /\ UNCHANGED now

TimerFires ==
  /\ \E a \in alarm : now >= a
  /\ m' = Settle(m, now)
  /\ alarm' = Alarm(m', now)
  /\ UNCHANGED <<now, presses, lastPressAt>>

TimePasses ==
  /\ now < MaxTime
  /\ \A a \in alarm : now < a + MaxLate
  /\ now' = now + 1
  /\ UNCHANGED <<m, alarm, presses, lastPressAt>>

EndOfCheckedTime ==
  /\ now = MaxTime
  /\ UNCHANGED vars

Next ==
  \/ \E p \in Press : UserPresses(p)
  \/ TimerFires
  \/ TimePasses
  \/ EndOfCheckedTime

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* What the listener hears at time t *)

Sounding(t) == {v \in m.voices : v.startsAt <= t /\ (~v.fading \/ t < v.fadeEnd)}
AtFullVolume(t) == {v \in m.voices : v.startsAt + Crossfade <= t /\ (~v.fading \/ t < v.fadeStart)}

HearsTheIntent ==
  IF m.intent.playing
    THEN \E v \in Sounding(now) : Sounding(now) = {v} /\ v.asset = m.intent.asset /\ ~v.fading
    ELSE Sounding(now) = {}

-----------------------------------------------------------------------------
(* Invariants: true in every reachable state *)

SingleTail == Cardinality(Tail(m)) <= 1

AtMostTwoVoices == Cardinality(m.voices) <= 2

GridExistsExactlyWhileSomethingIsAlive == (m.grid = {}) <=> (m.voices = {})

\* Every voice starts on the grid, at the loop position the grid implies, so all
\* loops stay phase-locked to the first one.
EveryVoiceIsOnTheGrid ==
  m.grid # {} => \A v \in m.voices :
    /\ (v.startsAt - G(m).anchor) % Tick = 0
    /\ v.offset = (v.startsAt - G(m).anchor) % Loop

\* Two loops are never both at full volume; overlap only happens inside a fade.
NeverTwoLoopsAtFullVolume == Cardinality(AtFullVolume(now)) <= 1

\* Stop pressing, and within a fixed time you hear exactly what you selected.
\* Lateness up to a tick costs at most one extra tick, never a wrong sound.
\* A press just after a boundary was locked waits one tick for the next one,
\* then the fade has to finish. Timer lateness within DecideAhead - Lead is
\* free. Beyond it, see Looper.timer-starves.cfg.
ResponseBound == DecideAhead + Tick + LongFade - ShortenBoundBy

RespondsWithinBound ==
  (lastPressAt >= 0 /\ now >= lastPressAt + ResponseBound) => HearsTheIntent

-----------------------------------------------------------------------------
(* Step properties: true of every transition *)

Ids(vs) == {v.id : v \in vs}

\* A voice is only ever removed after its fade-out has finished: no clicks.
NoVoiceIsCut ==
  \A v \in m.voices : v.id \notin Ids(m'.voices) => v.fading /\ v.fadeEnd <= now

\* Everything newly scheduled is at least Lead in the future.
NothingIsScheduledTooLate ==
  /\ \A v \in m'.voices : v.id \notin Ids(m.voices) => v.startsAt >= now + Lead
  /\ \A v \in m'.voices : \A old \in m.voices :
       (old.id = v.id /\ v.fading /\ ~old.fading) => v.fadeStart >= now + Lead

\* Scheduled audio is never rewritten. The only change a live voice may see is
\* gaining a fade-out it did not have.
ScheduledAudioIsImmutable ==
  \A v \in m'.voices : \A old \in m.voices :
    old.id = v.id =>
      \/ v = old
      \/ /\ ~old.fading /\ v.fading
         /\ [v EXCEPT !.fading = FALSE, !.fadeStart = 0, !.fadeEnd = 0] = old

Steps == [][NoVoiceIsCut /\ NothingIsScheduledTooLate /\ ScheduledAudioIsImmutable]_vars
=============================================================================

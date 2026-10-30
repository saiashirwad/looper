export type Ms = number

export const PATTERNS = [1, 2, 3, 4, 5, 6, 7, 8] as const
export const CHORDS = ['C', 'Dm', 'Em', 'F', 'G', 'Am', 'D', 'E'] as const
export const STRENGTHS = ['s', 'm', 'v'] as const

export type Pattern = (typeof PATTERNS)[number]
export type Chord = (typeof CHORDS)[number]
export type Strength = (typeof STRENGTHS)[number]

export interface Asset {
  readonly pattern: Pattern
  readonly chord: Chord
  readonly strength: Strength
}

/** What the user has selected. Presses edit this and nothing else. */
export interface Intent {
  readonly asset: Asset
  readonly playing: boolean
}

export interface Fade {
  readonly from: Ms
  readonly until: Ms
}

/** One looping playback. Once scheduled, the only change it can see is gaining a fade-out. */
export interface Voice {
  readonly id: number
  readonly asset: Asset
  readonly startsAt: Ms
  /** Position inside the loop at `startsAt`, so every voice is phase-locked to the grid. */
  readonly offset: Ms
  readonly fadeOut: Fade | null
}

/** Exists exactly while some voice exists. `decided` is the last boundary whose audio is fixed. */
export interface Grid {
  readonly anchor: Ms
  readonly decided: Ms
}

export interface State {
  readonly intent: Intent
  readonly voices: readonly Voice[]
  readonly grid: Grid | null
  readonly nextId: number
}

export type Press =
  | { readonly kind: 'pattern'; readonly pattern: Pattern }
  | { readonly kind: 'chord'; readonly chord: Chord }
  | { readonly kind: 'strength'; readonly strength: Strength }

export type Event =
  | { readonly type: 'press'; readonly press: Press; readonly at: Ms }
  | { readonly type: 'wake'; readonly at: Ms }

export type Command =
  | { readonly type: 'start'; readonly voice: Voice }
  | { readonly type: 'fadeOut'; readonly id: number; readonly fade: Fade }
  | { readonly type: 'dispose'; readonly id: number }

export interface Timing {
  readonly tick: Ms
  readonly loop: Ms
  /** The least distance into the future the audio engine can be trusted to schedule. */
  readonly lead: Ms
  /** How early a boundary gets locked in. `decideAhead - lead` is the timer-lateness budget. */
  readonly decideAhead: Ms
  readonly crossfade: Ms
  readonly longFade: Ms
}

export const TIMING: Timing = {
  tick: 1000,
  loop: 8000,
  lead: 20,
  decideAhead: 60,
  crossfade: 5,
  longFade: 300,
}

export const initialState = (asset: Asset): State => ({
  intent: { asset, playing: false },
  voices: [],
  grid: null,
  nextId: 1,
})

export const sameAsset = (a: Asset, b: Asset) =>
  a.pattern === b.pattern && a.chord === b.chord && a.strength === b.strength

const tail = (s: State) => s.voices.find(v => v.fadeOut === null)

export const audioMatchesIntent = (s: State) => {
  const t = tail(s)
  return s.intent.playing ? t !== undefined && sameAsset(t.asset, s.intent.asset) : t === undefined
}

const applyPress = (intent: Intent, press: Press): Intent => {
  switch (press.kind) {
    case 'pattern':
      return intent.playing && intent.asset.pattern === press.pattern
        ? { ...intent, playing: false }
        : { playing: true, asset: { ...intent.asset, pattern: press.pattern } }
    case 'chord':
      return { ...intent, asset: { ...intent.asset, chord: press.chord } }
    case 'strength':
      return { ...intent, asset: { ...intent.asset, strength: press.strength } }
  }
}

/** The earliest boundary after `decided` that can still be scheduled at `now`. */
const target = (grid: Grid | null, now: Ms, t: Timing): Ms => {
  if (grid === null) return now + t.lead
  const first = grid.decided + t.tick
  if (first >= now + t.lead) return first
  return first + Math.ceil((now + t.lead - first) / t.tick) * t.tick
}

const dispose = (s: State, now: Ms): State => {
  const voices = s.voices.filter(v => v.fadeOut === null || v.fadeOut.until > now)
  return { ...s, voices, grid: voices.length === 0 ? null : s.grid }
}

const commitDue = (s: State, now: Ms, t: Timing) =>
  !audioMatchesIntent(s) && (s.grid === null || now >= target(s.grid, now, t) - t.decideAhead)

const commit = (s: State, now: Ms, t: Timing): State => {
  const at = target(s.grid, now, t)
  const anchor = s.grid?.anchor ?? at
  const fadeLength = s.intent.playing ? t.crossfade : t.longFade
  const faded = s.voices.map(v =>
    v.fadeOut === null ? { ...v, fadeOut: { from: at, until: at + fadeLength } } : v,
  )
  const fresh: Voice = {
    id: s.nextId,
    asset: s.intent.asset,
    startsAt: at,
    offset: (at - anchor) % t.loop,
    fadeOut: null,
  }
  return {
    ...s,
    voices: s.intent.playing ? [...faded, fresh] : faded,
    grid: { anchor, decided: at },
    nextId: s.nextId + 1,
  }
}

const settle = (s: State, now: Ms, t: Timing): State => {
  const d = dispose(s, now)
  return commitDue(d, now, t) ? commit(d, now, t) : d
}

/** What the audio engine must do to go from `before` to `after`. */
export const diff = (before: readonly Voice[], after: readonly Voice[]): Command[] => {
  const old = new Map(before.map(v => [v.id, v]))
  const kept = new Set(after.map(v => v.id))
  return [
    ...before.filter(v => !kept.has(v.id)).map(v => ({ type: 'dispose', id: v.id }) as const),
    ...after.flatMap((v): Command[] => {
      const was = old.get(v.id)
      if (was === undefined) return [{ type: 'start', voice: v }]
      if (was.fadeOut === null && v.fadeOut !== null) return [{ type: 'fadeOut', id: v.id, fade: v.fadeOut }]
      return []
    }),
  ]
}

export const step = (s: State, e: Event, t: Timing = TIMING): { state: State; commands: Command[] } => {
  const edited = e.type === 'press' ? { ...s, intent: applyPress(s.intent, e.press) } : s
  const state = settle(edited, e.at, t)
  return { state, commands: diff(s.voices, state.voices) }
}

/** The one time the driver must wake up next, or null when nothing is pending. */
export const nextWakeup = (s: State, now: Ms, t: Timing = TIMING): Ms | null => {
  const times = s.voices.flatMap(v => (v.fadeOut ? [v.fadeOut.until] : []))
  if (!audioMatchesIntent(s) && s.grid !== null) times.push(target(s.grid, now, t) - t.decideAhead)
  return times.length === 0 ? null : Math.min(...times)
}

export const sounding = (s: State, now: Ms) =>
  s.voices.filter(v => v.startsAt <= now && (v.fadeOut === null || now < v.fadeOut.until))

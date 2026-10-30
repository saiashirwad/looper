import { describe, expect, test } from 'bun:test'

import {
  type Asset,
  CHORDS,
  type Command,
  type Event,
  initialState,
  type Ms,
  nextWakeup,
  PATTERNS,
  type Pattern,
  type Press,
  type State,
  STRENGTHS,
  step,
  TIMING,
  type Timing,
} from '../src/model.ts'
import { hearsTheIntent, responseBound, stateProperties, stepProperties } from './properties.ts'

const start: Asset = { pattern: 1, chord: 'C', strength: 'm' }
const pattern = (p: Pattern): Press => ({ kind: 'pattern', pattern: p })

/** Feeds presses at the given times and fires the timer exactly on time in between. */
const run = (presses: ReadonlyArray<readonly [Ms, Press]>, until: Ms, t: Timing = TIMING) => {
  let state: State = initialState(start)
  const log: Array<{ at: Ms; commands: Command[] }> = []
  let now = 0
  const apply = (e: Event) => {
    const r = step(state, e, t)
    state = r.state
    now = e.at
    if (r.commands.length > 0) log.push({ at: e.at, commands: r.commands })
  }
  const drainUntil = (limit: Ms) => {
    for (let w = nextWakeup(state, now, t); w !== null && w <= limit; w = nextWakeup(state, now, t))
      apply({ type: 'wake', at: Math.max(w, now) })
  }
  for (const [at, press] of presses) {
    drainUntil(at)
    apply({ type: 'press', press, at })
  }
  drainUntil(until)
  return { state, log }
}

describe('behaviour', () => {
  test('from silence a pattern starts right away, at loop position 0', () => {
    const { log } = run([[500, pattern(1)]], 600)
    expect(log).toEqual([
      { at: 500, commands: [{ type: 'start', voice: { id: 1, asset: start, startsAt: 520, offset: 0, fadeOut: null } }] },
    ])
  })

  test('another pattern crossfades in on the next tick, phase-locked to the first loop', () => {
    const { log } = run([[0, pattern(1)], [300, pattern(2)]], 2000)
    expect(log[1]).toEqual({
      at: 960,
      commands: [
        { type: 'fadeOut', id: 1, fade: { from: 1020, until: 1025 } },
        { type: 'start', voice: { id: 2, asset: { ...start, pattern: 2 }, startsAt: 1020, offset: 1000, fadeOut: null } },
      ],
    })
    expect(log[2]).toEqual({ at: 1025, commands: [{ type: 'dispose', id: 1 }] })
  })

  test('changing your mind before the deadline costs no audio work at all', () => {
    const { log } = run([[0, pattern(1)], [300, pattern(2)], [700, pattern(1)]], 3000)
    expect(log).toHaveLength(1)
  })

  test("triple-tapping one pattern plays, stops, plays; it never dies", () => {
    const deadline = 1020 - TIMING.decideAhead
    for (const third of [deadline - 1, deadline, deadline + 1, 1020, 1300, 1900]) {
      const { state } = run([[0, pattern(1)], [deadline - 5, pattern(1)], [third, pattern(1)]], 6000)
      expect(state.intent.playing).toBe(true)
      expect(hearsTheIntent(state, 6000)).toBe(true)
    }
  })

  test('a chord change keeps the pattern and the loop position', () => {
    const { log } = run([[0, pattern(3)], [2500, { kind: 'chord', chord: 'Am' }]], 4000)
    const started = log.flatMap(l => l.commands).filter(c => c.type === 'start')
    expect(started.at(-1)).toMatchObject({ voice: { asset: { pattern: 3, chord: 'Am' }, startsAt: 3020, offset: 3000 } })
  })

  test('a timer too late for its boundary moves to the next one instead of scheduling into the past', () => {
    let s = step(initialState(start), { type: 'press', press: pattern(1), at: 0 }).state
    s = step(s, { type: 'press', press: pattern(2), at: 100 }).state
    const lateBy = TIMING.decideAhead - TIMING.lead + 1
    const late = step(s, { type: 'wake', at: nextWakeup(s, 100)! + lateBy })
    expect(late.commands).toEqual([])
    const rearmed = nextWakeup(late.state, 1001)!
    expect(rearmed).toBe(2020 - TIMING.decideAhead)
    expect(step(late.state, { type: 'wake', at: rearmed }).commands).toContainEqual({
      type: 'fadeOut',
      id: 1,
      fade: { from: 2020, until: 2025 },
    })
  })
})

const mulberry32 = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let x = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x
  return ((x ^ (x >>> 14)) >>> 0) / 4294967296
}

const randomPress = (r: () => number): Press => {
  const pick = <T>(xs: readonly T[]) => xs[Math.floor(r() * xs.length)]!
  const k = r()
  if (k < 0.6) return { kind: 'pattern', pattern: pick(PATTERNS.slice(0, 3)) }
  if (k < 0.8) return { kind: 'chord', chord: pick(CHORDS.slice(0, 3)) }
  return { kind: 'strength', strength: pick(STRENGTHS) }
}

/** Every time at which `sounding` or the at-full-volume set can change, plus its neighbours. */
const probes = (s: State, from: Ms, to: Ms, t: Timing, extra: Ms[]) =>
  [
    from,
    ...extra,
    ...s.voices.flatMap(v => [v.startsAt, v.startsAt + t.crossfade, ...(v.fadeOut ? [v.fadeOut.from, v.fadeOut.until] : [])]),
  ]
    .flatMap(x => [x - 1, x, x + 1])
    .filter(x => x >= from && x < to)

const simulate = (seed: number, t: Timing, maxLate: Ms) => {
  const r = mulberry32(seed)
  let state = initialState(start)
  let now = 0
  let lastPress = Number.NEGATIVE_INFINITY
  let nextPress: Ms = Math.floor(r() * 1500)
  let presses = 0
  const failures: string[] = []
  const horizon = 20_000

  while (now < horizon) {
    const alarm = nextWakeup(state, now, t)
    const fire = alarm === null ? Number.POSITIVE_INFINITY : Math.max(now, alarm + Math.floor(r() * (maxLate + 1)))
    const pressing = presses < 12 && nextPress <= fire
    const at = Math.min(pressing ? nextPress : fire, horizon)

    const settled = lastPress + responseBound(t)
    for (const p of probes(state, now, at, t, [settled])) {
      for (const b of stateProperties(state, p, t)) failures.push(`${b} at ${p}`)
      if (p >= settled && !hearsTheIntent(state, p)) failures.push(`RespondsWithinBound at ${p}`)
    }
    if (at === horizon) break

    const event: Event = pressing ? { type: 'press', press: randomPress(r), at } : { type: 'wake', at }
    const after = step(state, event, t).state
    for (const b of [...stepProperties(state, after, at, t), ...stateProperties(after, at, t)])
      failures.push(`${b} after ${event.type} at ${at}`)
    if (pressing) {
      presses++
      lastPress = at
      nextPress = at + Math.floor(r() * (r() < 0.5 ? 120 : 1800))
    }
    state = after
    now = at
  }
  return failures
}

describe('properties from Looper.tla, on the real constants', () => {
  test('5000 random sessions, timer late by up to decideAhead - lead', () => {
    const maxLate = TIMING.decideAhead - TIMING.lead
    for (let seed = 1; seed <= 5000; seed++) {
      const failures = simulate(seed, TIMING, maxLate)
      if (failures.length > 0) throw new Error(`seed ${seed}: ${failures.slice(0, 5).join(', ')}`)
    }
  })

  test('the checks have teeth: a timer later than the budget breaks the response bound', () => {
    const tooLate = TIMING.decideAhead - TIMING.lead + 200
    const anyFailed = Array.from({ length: 300 }, (_, i) => simulate(i + 1, TIMING, tooLate)).some(f =>
      f.some(x => x.startsWith('RespondsWithinBound')),
    )
    expect(anyFailed).toBe(true)
  })

  test('the checks have teeth: a fade-to-silence longer than two ticks allows a third voice', () => {
    const longFade = { ...TIMING, longFade: 2500 }
    const failures = Array.from({ length: 300 }, (_, i) => simulate(i + 1, longFade, 0)).flat()
    expect(failures.some(x => x.startsWith('AtMostTwoVoices'))).toBe(true)
  })
})

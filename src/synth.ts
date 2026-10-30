import { type Asset, type Chord, STRENGTHS, TIMING } from './model.ts'

const TRIADS: Record<Chord, readonly number[]> = {
  C: [60, 64, 67],
  Dm: [62, 65, 69],
  Em: [64, 67, 71],
  F: [65, 69, 72],
  G: [67, 71, 74],
  Am: [69, 72, 76],
  D: [62, 66, 69],
  E: [64, 68, 71],
}

const hz = (midi: number) => 440 * 2 ** ((midi - 69) / 12)

/** Eighth-note steps of an 8-second, 120 bpm loop. Each pattern is a different rhythm and note order. */
const STEPS = 32
const hits = (pattern: number, step: number) => (step * (pattern + 2) + pattern) % 7 < 3

/** Stand-in for the real recorded loops: a plucked arpeggio per (pattern, chord, strength). */
export const makeBufferStore = (ctx: BaseAudioContext) => {
  const cache = new Map<string, AudioBuffer>()
  return (asset: Asset) => {
    const key = `${asset.pattern}.${asset.chord}.${asset.strength}`
    const cached = cache.get(key)
    if (cached) return cached

    const rate = ctx.sampleRate
    const buffer = ctx.createBuffer(1, Math.round((TIMING.loop / 1000) * rate), rate)
    const data = buffer.getChannelData(0)
    const stepLength = data.length / STEPS
    const level = 0.12 + 0.1 * STRENGTHS.indexOf(asset.strength)
    const notes = TRIADS[asset.chord]
    for (let step = 0; step < STEPS; step++) {
      if (!hits(asset.pattern, step)) continue
      const f = hz((notes[(step * asset.pattern) % notes.length] ?? 60) + (step % 8 === 0 ? -12 : 0))
      const begin = Math.round(step * stepLength)
      const length = Math.min(Math.round(stepLength * 2), data.length - begin)
      for (let i = 0; i < length; i++) {
        const t = i / rate
        const envelope = Math.exp(-t * 9) * Math.min(1, i / 64)
        data[begin + i]! += level * envelope * (Math.sin(2 * Math.PI * f * t) + 0.3 * Math.sin(4 * Math.PI * f * t))
      }
    }
    cache.set(key, buffer)
    return buffer
  }
}

import { createDriver } from './driver.ts'
import { CHORDS, PATTERNS, type Press, type State, STRENGTHS } from './model.ts'
import { makeBufferStore } from './synth.ts'

const PATTERN_KEYS = '12345678'
const CHORD_KEYS = 'qwertyui'
const STRENGTH_KEYS = 'asd'

const KEYS: Record<string, Press> = {
  ...Object.fromEntries(PATTERNS.map((pattern, i) => [PATTERN_KEYS[i]!, { kind: 'pattern', pattern }])),
  ...Object.fromEntries(CHORDS.map((chord, i) => [CHORD_KEYS[i]!, { kind: 'chord', chord }])),
  ...Object.fromEntries(STRENGTHS.map((strength, i) => [STRENGTH_KEYS[i]!, { kind: 'strength', strength }])),
}

const row = (id: string, labels: readonly string[], keys: string) => {
  document.getElementById(id)!.replaceChildren(
    ...labels.map((label, i) => {
      const b = document.createElement('button')
      const kbd = document.createElement('kbd')
      b.dataset.key = kbd.textContent = keys[i]!
      b.append(label, kbd)
      return b
    }),
  )
}
row('patterns', PATTERNS.map(String), PATTERN_KEYS)
row('chords', CHORDS, CHORD_KEYS)
row('strengths', STRENGTHS, STRENGTH_KEYS)

const render = (state: State, now: number) => {
  const { asset, playing } = state.intent
  const patternKey = PATTERN_KEYS[PATTERNS.indexOf(asset.pattern)]
  const selected = new Set([
    patternKey,
    CHORD_KEYS[CHORDS.indexOf(asset.chord)],
    STRENGTH_KEYS[STRENGTHS.indexOf(asset.strength)],
  ])
  for (const b of document.querySelectorAll<HTMLButtonElement>('button[data-key]')) {
    b.classList.toggle('selected', selected.has(b.dataset.key))
    b.classList.toggle('playing', playing && b.dataset.key === patternKey)
  }
  document.getElementById('voices')!.textContent =
    state.voices
      .map(v => {
        const a = `${v.asset.pattern}.${v.asset.chord}.${v.asset.strength}`
        const fade = v.fadeOut ? `fades ${v.fadeOut.from}→${v.fadeOut.until}` : 'looping'
        return `#${v.id}  ${a.padEnd(8)} from ${v.startsAt} @${v.offset}  ${fade}`
      })
      .join('\n') || 'silence'
  document.getElementById('now')!.textContent = `${now} ms`
}

let driver: ReturnType<typeof createDriver> | undefined
const press = (key: string) => {
  const p = KEYS[key]
  if (!p) return
  if (!driver) {
    const ctx = new AudioContext()
    driver = createDriver(ctx, makeBufferStore(ctx), { pattern: 1, chord: 'C', strength: 'm' }, render)
  }
  driver.press(p)
}

addEventListener('keydown', (e: KeyboardEvent) => {
  if (!e.repeat && !e.metaKey && !e.ctrlKey && !e.altKey) press(e.key)
})
addEventListener('click', e => {
  const key = (e.target as HTMLElement).closest('button')?.dataset.key
  if (key) press(key)
})

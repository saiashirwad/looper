import { expect, test } from 'bun:test'
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  type Asset,
  type Chord,
  type Event,
  type Grid,
  initialState,
  type Ms,
  nextWakeup,
  type Pattern,
  type Press,
  type State,
  step,
  type Timing,
  type Voice,
} from '../src/model.ts'

/**
 * Replays random runs of quint/looper.qnt through src/model.ts and checks that after every
 * step both are in the same state. The properties tests show each copy is correct on its
 * own; this shows they are the same machine.
 */

const TRACES = 500
const STEPS = 40
const SEED = '1'

/** The constants of `module defaults` in quint/looper.qnt. */
const QUINT_TIMING: Timing = { tick: 4, loop: 8, lead: 1, decideAhead: 2, crossfade: 1, longFade: 2 }

/** Quint's P1..P3 are patterns 1..3; its one variant dimension stands in for chord. */
const PATTERN: Record<string, Pattern> = { P1: 1, P2: 2, P3: 3 }
const VARIANT: Record<string, Chord> = { V1: 'C', V2: 'Dm' }
const START: Asset = { pattern: 1, chord: 'C', strength: 'm' }

type Itf = { readonly [key: string]: Itf } & { readonly tag?: string; readonly value?: Itf }

/** Decodes the ITF encoding of ints, sets and options into plain values. */
const num = (x: Itf): number => Number((x as unknown as { '#bigint': string })['#bigint'])
const set = (x: Itf): Itf[] => (x as unknown as { '#set': Itf[] })['#set']
const option = <T>(x: Itf, f: (v: Itf) => T): T | null => (x.tag === 'Some' ? f(x.value!) : null)

const asset = (x: Itf): Asset => ({ ...START, pattern: PATTERN[x.pattern!.tag!]!, chord: VARIANT[x.variant!.tag!]! })

const voice = (x: Itf): Voice => ({
  id: num(x.id!),
  asset: asset(x.asset!),
  startsAt: num(x.startsAt!),
  offset: num(x.offset!),
  fadeOut: option(x.fadeOut!, f => ({ from: num(f.from!), until: num(f.until!) })),
})

const machine = (x: Itf): State => ({
  intent: { asset: asset(x.intent!.asset!), playing: (x.intent!.playing as unknown) === true },
  voices: set(x.voices!).map(voice),
  grid: option(x.grid!, (g): Grid => ({ anchor: num(g.anchor!), decided: num(g.decided!) })),
  nextId: num(x.nextId!),
})

const press = (x: Itf): Press =>
  x.tag === 'PatternPress'
    ? { kind: 'pattern', pattern: PATTERN[x.value!.tag!]! }
    : { kind: 'chord', chord: VARIANT[x.value!.tag!]! }

/** Voice order is not part of the state: Quint keeps a set, the model a list. */
const normalize = (s: State) => ({ ...s, voices: [...s.voices].sort((a, b) => a.id - b.id) })

const generateTraces = () => {
  const dir = mkdtempSync(join(tmpdir(), 'looper-itf-'))
  const run = Bun.spawnSync(
    [
      'quint', 'run', 'looper.qnt', '--main', 'defaults', '--invariant', 'safety', '--mbt',
      '--max-samples', String(TRACES), '--n-traces', String(TRACES), '--max-steps', String(STEPS),
      '--seed', SEED, '--out-itf', join(dir, 'trace_{seq}.itf.json'),
    ],
    { cwd: join(import.meta.dir, '../quint') },
  )
  if (run.exitCode !== 0) throw new Error(`quint run failed:\n${run.stdout}${run.stderr}`)
  return readdirSync(dir).map(f => join(dir, f))
}

test.skipIf(Bun.which('quint') === null)(
  `the model takes the same steps as quint/looper.qnt (${TRACES} random runs)`,
  () => {
    const files = generateTraces()
    expect(files).toHaveLength(TRACES)

    for (const file of files) {
      const states = (JSON.parse(readFileSync(file, 'utf8')) as { states: Itf[] }).states
      let state = initialState(START)
      let alarm = null as Ms | null

      for (const [i, s] of states.entries()) {
        const action = s['mbt::actionTaken'] as unknown as string
        const now = num(s['defaults::looper::now']!)
        const react = (e: Event) => {
          state = step(state, e, QUINT_TIMING).state
          alarm = nextWakeup(state, e.at, QUINT_TIMING)
        }
        if (action === 'userPresses') {
          react({ type: 'press', press: press(s['mbt::nondetPicks']!.p!.value!), at: now })
        } else if (action === 'timerFires') {
          react({ type: 'wake', at: now })
        } else if (!['init', 'timePasses', 'endOfCheckedTime'].includes(action)) {
          throw new Error(`unknown Quint action ${action}`)
        }

        const where = `${file}, state ${i} (${action} at ${now})`
        expect(normalize(state), where).toEqual(normalize(machine(s['defaults::looper::m']!)))
        expect(alarm, where).toEqual(option(s['defaults::looper::alarm']!, num))
      }
    }
  },
  60_000,
)

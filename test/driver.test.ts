import { expect, test } from 'bun:test'

import { createDriver } from '../src/driver.ts'

const fakeContext = () => {
  const calls: string[] = []
  const param = { setValueAtTime: (v: number, t: number) => calls.push(`gain ${v} @${t}`), linearRampToValueAtTime: (v: number, t: number) => calls.push(`ramp ${v} @${t}`) }
  const ctx = {
    currentTime: 0,
    destination: {},
    createBufferSource: () => ({
      buffer: null,
      loop: false,
      connect: (g: unknown) => g,
      start: (t: number, offset: number) => calls.push(`start @${t} offset ${offset}`),
      stop: () => calls.push('stop'),
    }),
    createGain: () => ({ gain: param, connect: () => {}, disconnect: () => calls.push('disconnect') }),
  }
  return { ctx: ctx as unknown as AudioContext & { currentTime: number }, calls }
}

test('the driver turns model commands into Web Audio calls and re-arms its timer', async () => {
  const { ctx, calls } = fakeContext()
  const driver = createDriver(ctx, () => ({}) as AudioBuffer, { pattern: 1, chord: 'C', strength: 'm' }, () => {})
  driver.press({ kind: 'pattern', pattern: 1 })
  expect(calls).toEqual(['gain 0 @0.02', 'ramp 1 @0.025', 'start @0.02 offset 0'])

  calls.length = 0
  ctx.currentTime = 0.3
  driver.press({ kind: 'pattern', pattern: 2 })
  expect(calls).toEqual([])

  ctx.currentTime = 0.96
  await Bun.sleep(700)
  expect(calls).toEqual(['gain 1 @1.02', 'ramp 0 @1.025', 'gain 0 @1.02', 'ramp 1 @1.025', 'start @1.02 offset 1'])

  calls.length = 0
  ctx.currentTime = 1.025
  await Bun.sleep(100)
  expect(calls).toEqual(['stop', 'disconnect'])
})

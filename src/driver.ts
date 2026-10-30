import { type Asset, type Command, type Event, initialState, nextWakeup, type Press, type State, step, TIMING } from './model.ts'

interface Playing {
  readonly source: AudioBufferSourceNode
  readonly gain: GainNode
}

/**
 * The only impure part: turns commands into Web Audio calls and keeps one timer
 * armed for `nextWakeup`. Everything it decides comes from the model.
 */
export const createDriver = (
  ctx: AudioContext,
  bufferFor: (asset: Asset) => AudioBuffer,
  initial: Asset,
  onChange: (state: State, now: number) => void,
) => {
  let state = initialState(initial)
  let timer: ReturnType<typeof setTimeout> | undefined
  const playing = new Map<number, Playing>()
  const nowMs = () => Math.floor(ctx.currentTime * 1000)
  const sec = (ms: number) => ms / 1000

  const execute = (c: Command) => {
    switch (c.type) {
      case 'start': {
        const { voice } = c
        const source = ctx.createBufferSource()
        source.buffer = bufferFor(voice.asset)
        source.loop = true
        const gain = ctx.createGain()
        gain.gain.setValueAtTime(0, sec(voice.startsAt))
        gain.gain.linearRampToValueAtTime(1, sec(voice.startsAt + TIMING.crossfade))
        source.connect(gain).connect(ctx.destination)
        source.start(sec(voice.startsAt), sec(voice.offset))
        playing.set(voice.id, { source, gain })
        return
      }
      case 'fadeOut': {
        const node = playing.get(c.id)
        node?.gain.gain.setValueAtTime(1, sec(c.fade.from))
        node?.gain.gain.linearRampToValueAtTime(0, sec(c.fade.until))
        return
      }
      case 'dispose': {
        const node = playing.get(c.id)
        node?.source.stop()
        node?.gain.disconnect()
        playing.delete(c.id)
        return
      }
    }
  }

  const dispatch = (event: Event) => {
    const result = step(state, event)
    state = result.state
    result.commands.forEach(execute)
    clearTimeout(timer)
    const wake = nextWakeup(state, event.at)
    if (wake !== null)
      timer = setTimeout(() => dispatch({ type: 'wake', at: nowMs() }), Math.max(0, wake - nowMs()))
    onChange(state, event.at)
  }

  return {
    press: (press: Press) => dispatch({ type: 'press', press, at: nowMs() }),
    state: () => state,
    now: nowMs,
  }
}

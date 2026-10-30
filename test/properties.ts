import { type Ms, type State, sameAsset, sounding, type Timing } from '../src/model.ts'

/** The same properties Looper.tla checks, over the real implementation. */

export const stateProperties = (s: State, now: Ms, t: Timing): string[] => {
  const broken: string[] = []
  if (s.voices.filter(v => v.fadeOut === null).length > 1) broken.push('SingleTail')
  if (s.voices.length > 2) broken.push('AtMostTwoVoices')
  if ((s.grid === null) !== (s.voices.length === 0)) broken.push('GridExistsExactlyWhileSomethingIsAlive')
  for (const v of s.voices) {
    const sinceAnchor = v.startsAt - (s.grid?.anchor ?? Number.NaN)
    if (sinceAnchor % t.tick !== 0 || v.offset !== sinceAnchor % t.loop) broken.push('EveryVoiceIsOnTheGrid')
  }
  const atFull = s.voices.filter(
    v => v.startsAt + t.crossfade <= now && (v.fadeOut === null || now < v.fadeOut.from),
  )
  if (atFull.length > 1) broken.push('NeverTwoLoopsAtFullVolume')
  return broken
}

export const hearsTheIntent = (s: State, now: Ms) => {
  const heard = sounding(s, now)
  if (!s.intent.playing) return heard.length === 0
  const [only] = heard
  return heard.length === 1 && only !== undefined && only.fadeOut === null && sameAsset(only.asset, s.intent.asset)
}

export const responseBound = (t: Timing) => t.decideAhead + t.tick + t.longFade

export const stepProperties = (before: State, after: State, now: Ms, t: Timing): string[] => {
  const broken: string[] = []
  const old = new Map(before.voices.map(v => [v.id, v]))
  const kept = new Set(after.voices.map(v => v.id))
  for (const v of before.voices)
    if (!kept.has(v.id) && (v.fadeOut === null || v.fadeOut.until > now)) broken.push('NoVoiceIsCut')
  for (const v of after.voices) {
    const was = old.get(v.id)
    if (was === undefined) {
      if (v.startsAt < now + t.lead) broken.push('NothingIsScheduledTooLate')
      continue
    }
    if (was === v) continue
    const gainedFade = was.fadeOut === null && v.fadeOut !== null && { ...v, fadeOut: null }
    if (!gainedFade || JSON.stringify(gainedFade) !== JSON.stringify(was)) broken.push('ScheduledAudioIsImmutable')
    else if (v.fadeOut && v.fadeOut.from < now + t.lead) broken.push('NothingIsScheduledTooLate')
  }
  return broken
}

import { createDriver } from "./driver.ts";
import { CHORDS, PATTERNS, type Press, type State, STRENGTHS } from "./model.ts";
import { makeBufferStore } from "./synth.ts";

const KEYS: Record<string, Press> = {
  ...Object.fromEntries(
    PATTERNS.map((pattern, i) => [String(i + 1), { kind: "pattern", pattern }]),
  ),
  ...Object.fromEntries(CHORDS.map((chord, i) => ["qwertyui"[i]!, { kind: "chord", chord }])),
  ...Object.fromEntries(
    STRENGTHS.map((strength, i) => ["asd"[i]!, { kind: "strength", strength }]),
  ),
};

const row = (id: string, labels: readonly string[], keys: string) => {
  const el = document.getElementById(id)!;
  el.replaceChildren(
    ...labels.map((label, i) => {
      const b = document.createElement("button");
      b.dataset.key = keys[i];
      b.innerHTML = `${label}<kbd>${keys[i]}</kbd>`;
      return b;
    }),
  );
};
row("patterns", PATTERNS.map(String), "12345678");
row("chords", CHORDS, "qwertyui");
row("strengths", STRENGTHS, "asd");

const render = (state: State, now: number) => {
  const { asset, playing } = state.intent;
  const selected = new Set([
    String(PATTERNS.indexOf(asset.pattern) + 1),
    "qwertyui"[CHORDS.indexOf(asset.chord)],
    "asd"[STRENGTHS.indexOf(asset.strength)],
  ]);
  for (const b of document.querySelectorAll<HTMLButtonElement>("button[data-key]")) {
    b.classList.toggle("selected", selected.has(b.dataset.key));
    b.classList.toggle("playing", playing && b.dataset.key === String(asset.pattern));
  }
  document.getElementById("voices")!.textContent =
    state.voices
      .map((v) => {
        const a = `${v.asset.pattern}.${v.asset.chord}.${v.asset.strength}`;
        const fade = v.fadeOut ? `fades ${v.fadeOut.from}→${v.fadeOut.until}` : "looping";
        return `#${v.id}  ${a.padEnd(8)} from ${v.startsAt} @${v.offset}  ${fade}`;
      })
      .join("\n") || "silence";
  document.getElementById("now")!.textContent = `${now} ms`;
};

let driver: ReturnType<typeof createDriver> | undefined;
const press = (key: string) => {
  const p = KEYS[key];
  if (!p) return;
  if (!driver) {
    const ctx = new AudioContext();
    driver = createDriver(
      ctx,
      makeBufferStore(ctx),
      { pattern: 1, chord: "C", strength: "m" },
      render,
    );
  }
  driver.press(p);
};

addEventListener("keydown", (e: KeyboardEvent) => !e.repeat && press(e.key));
addEventListener("click", (e) => {
  const key = (e.target as HTMLElement).closest("button")?.dataset.key;
  if (key) press(key);
});

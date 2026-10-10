import { BEAT, OC_TOTAL_ROWS, OPENCODE_SCRIPT } from "../simData";
import type { OcLine } from "../simData";
import { OC_PANE_W } from "./geometry";
import { SPIN, raw, emo, spin, cat, padEnd, padStart, trunc } from "./segments";
import type { Seg } from "./segments";

// Live pane width. Set per render (buildOpencodeLines) so every pane helper
// pads/truncates to the width the current layout asked for: the side-by-side
// remainder, the full terminal when stacked, or OC_PANE_W on a default 88-col
// grid. Defaults to OC_PANE_W so Node-side asserts see the historical width.
let ocW = OC_PANE_W;

// ---- opencode pane (the "take the wheel" beat) ----
// Every pane row is exactly OC_PANE_W cols. No rail/box chrome: opencode's
// turns are delineated by background-tinted bands (oc-userblock / oc-field),
// an accent gutter glyph on cmd/tool lines, and plain prose otherwise.
const ocPad = (content: Seg): Seg => padEnd(content, ocW);
const ocPlain = (content: Seg): string => ocPad(content).h;
const ocBlank = (): string => ocPlain(raw(""));

// A full-width background band: pad to ocW *inside* the wrapping span so
// the background color covers the whole row (literal padding chars, not CSS
// width), keeping the Seg width model and the assert in agreement.
function ocBand(content: Seg, cls: string): string {
  return `<span class="${cls}">${ocPad(content).h}</span>`;
}

const ocGutter = (): Seg => ({ h: `<span class="oc-gutter">│</span>`, w: 1 });
const ocCursor = (): Seg => ({ h: `<span class="cursor"></span>`, w: 1 });
// Solid one-column accent bar for the banded rows (input field + posted user
// block). CSS gives the cell a filled background so the bands read as a single
// left rail rather than per-row glyphs.
const ocBar = (): Seg => ({ h: `<span class="oc-bar"> </span>`, w: 1 });

function ocHistory(line: OcLine): string {
  switch (line.kind) {
    case "cmd":
      return ocPlain(cat(ocGutter(), raw(" "), raw(trunc(line.text, ocW - 2), "oc-cmd")));
    case "tool":
      return ocPlain(cat(ocGutter(), raw(" "), raw(trunc(line.text, ocW - 2), "oc-tool")));
    case "prose":
      return ocPlain(raw(trunc(line.text, ocW)));
  }
}

// Executor typing: deterministic per-char reveal offsets (seconds from
// typeStart), seeded so the same loopSec always yields the same substring
// (R-V4/R-V9). Speed varies ~80–120ms/char but is a pure function of index.
const TYPE_OFFSETS: number[] = (() => {
  const offs: number[] = [];
  let t = 0;
  for (let i = 0; i < OPENCODE_SCRIPT.typedText.length; i++) {
    const r = ((i * 2654435761) >>> 0) % 100; // 0..99, deterministic
    t += 0.08 + (r / 99) * 0.04;
    offs.push(t);
  }
  return offs;
})();

function revealedInput(loopSec: number): string {
  const elapsed = loopSec - BEAT.typeStart;
  let n = 0;
  for (const o of TYPE_OFFSETS) if (o <= elapsed) n++;
  return OPENCODE_SCRIPT.typedText.slice(0, n);
}

// Three-row filled input field with a solid accent left bar: a blank row, the
// typed substring + blinking cursor (while [typeStart, sendAt); just the cursor
// otherwise), and the dim context label. At sendAt the text posts as an
// oc-userblock above (see builder). The leading blank row gives the box height.
function ocInputField(loopSec: number): string[] {
  const typing = loopSec >= BEAT.typeStart && loopSec < BEAT.sendAt;
  const shown = typing ? revealedInput(loopSec) : "";
  const blank = cat(ocBar(), raw(" "));
  const prompt = cat(
    ocBar(),
    raw(" "),
    raw("› ", "oc-prompt"),
    raw(trunc(shown, ocW - 5)),
    ocCursor(),
  );
  const label = cat(
    ocBar(),
    padStart(raw(trunc(OPENCODE_SCRIPT.inputLabel, ocW - 3), "dim"), ocW - 2),
    raw(" "),
  );
  return [
    ocBand(blank, "oc-field"),
    ocBand(prompt, "oc-field"),
    ocBand(label, "oc-field"),
  ];
}

// The posted Executor message — a full-width tinted band with the solid bar.
function ocUserBlock(text: string): string {
  return ocBand(cat(ocBar(), raw(" "), raw(trunc(text, ocW - 2))), "oc-userblock");
}

// The scrollback transcript in chronological order (oldest first). The history
// + alert + question head are present the moment the pane opens (R-V on-open);
// the three options post one-per-second from optStart, each with a greyed
// elaboration; the Executor’s posted block lands at sendAt and the reply at
// replyAt. The renderer bottom-anchors this list so the newest line sits just
// above the input and older lines scroll off the top (real opencode behavior).
function ocTranscript(loopSec: number): string[] {
  const s = OPENCODE_SCRIPT;
  const lines: string[] = [];
  for (const h of s.history) lines.push(ocHistory(h));
  lines.push(ocBlank());
  lines.push(ocPlain(cat(emo("❗"), raw(" "), raw(trunc(s.alertText, ocW - 3)))));
  lines.push(ocPlain(raw(trunc(s.questionHead, ocW))));
  s.options.forEach((opt, i) => {
    if (loopSec >= BEAT.optStart + i) {
      lines.push(ocPlain(raw(trunc(opt.label, ocW))));
      lines.push(ocPlain(raw("   " + trunc(opt.detail, ocW - 3), "oc-dim")));
    }
  });
  if (loopSec >= BEAT.sendAt) {
    lines.push(ocBlank());
    lines.push(ocUserBlock(s.typedText));
  }
  if (loopSec >= BEAT.replyAt) {
    lines.push(ocBlank());
    lines.push(ocPlain(raw(trunc(s.reply, ocW))));
  }
  return lines;
}

// Render the opencode pane as a fixed-height array of OC_PANE_W-col rows
// (`rows` total). Pure function of loopSec/spinIdx; the join in renderFrame
// stitches it beside the abbreviated dashboard. Turns appear whole on the 1Hz
// repaint; only the Executor’s input types char-by-char (R-V4) and the chip
// spinner ticks. The transcript is bottom-anchored: when it is shorter than the
// pane the top is padded with blanks; when longer, the oldest lines scroll off.
export function buildOpencodeLines(
  loopSec: number,
  spinIdx: number,
  rows: number = OC_TOTAL_ROWS,
  paneWidth: number = OC_PANE_W,
): string[] {
  ocW = paneWidth;
  const s = OPENCODE_SCRIPT;
  const chip = cat(
    raw("▣ ", "oc-chip"),
    raw(s.chip, "oc-chip"),
    raw("  "),
    spin(SPIN[spinIdx]),
  );

  const field = ocInputField(loopSec);
  // minus chip + one separator blank + input field
  const transcriptRows = rows - 2 - field.length;
  const transcript = ocTranscript(loopSec).slice(-transcriptRows);
  while (transcript.length < transcriptRows) transcript.unshift(ocBlank());

  return [ocPlain(chip), ...transcript, ocBlank(), ...field];
}

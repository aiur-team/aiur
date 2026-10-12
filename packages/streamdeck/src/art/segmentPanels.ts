/** The agent detail, voice, settings and commands panels of the touch strip. */
import type { SKRSContext2D } from "@napi-rs/canvas";

import type { SegmentContent } from "../touchStrip/stripLayout.js";
import {
  bucketContract,
  KEY_FACE_CONTRACT,
  progressBarColor,
  UNKNOWN_PROGRESS_COLOR,
  type BucketContract,
  type BucketId,
} from "../key-face-contract.js";
import { VOICE_HOLD_PROMPT, VOICE_LISTENING } from "../voicePanel.js";
import type { CommandsPanelModel } from "../commands.js";
import { fit, rightText } from "./segmentText.js";
import { createPaint } from "./gradient.js";
import { activityFragment, drawIcon, iconFragment } from "./icons.js";
import { drawVendorMark } from "./vendorMark.js";
import {
  LABEL,
  TEXT,
  MUTED,
  TRACK,
  ACCENT_LIVE,
  CHIP_FILL,
  CHIP_BORDER,
  PAD,
  HEIGHT,
  clamp,
  caption,
  meter,
} from "./segmentStyle.js";

import { CHAT_BODY_FONT, drawHint, OPENCODE } from "./chat-readout.js";

/**
 * The bucket contract for a status, or null when the daemon sent one the
 * contract does not define. `bucketContract` throws on an unknown state, which
 * is right where the state came from the compile-time-checked key path, but the
 * cmd panel's status is a free string off the wire — a repaint must not die
 * because a new bucket appeared server-side first.
 */
const knownBucket = (status: string): BucketContract | null =>
  Object.hasOwn(KEY_FACE_CONTRACT.states, status) ? bucketContract(status as BucketId) : null;

export const drawAgentDetail = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "agentDetail" }, now: number): void => {
  void now;
  const { model } = content;
  const bucket = knownBucket(model.status);
  const accent = bucket?.accent ?? LABEL;
  const summaryWidth = width / 4;

  const chip = 26;
  context.beginPath();
  context.roundRect(PAD, 8, chip, chip, 8);
  context.fillStyle = CHIP_FILL;
  context.fill();
  context.strokeStyle = CHIP_BORDER;
  context.lineWidth = 1;
  context.stroke();
  drawIcon(context, iconFragment(model.icon), PAD + 4.5, 12.5, 17, accent);
  drawVendorMark(context, model.vendor, PAD + chip + 7, 11, 20);

  context.font = "700 26px monospace";
  context.fillStyle = TEXT;
  context.fillText(fit(context, model.ticketId, summaryWidth - PAD * 2), PAD, 66);
  drawHint(context, "BACK", PAD, HEIGHT - 6, true, false);

  const left = summaryWidth + 8;
  const right = width - PAD;

  // An em dash rather than "0%": the key face for this same ticket is one
  // press away painting a flat-grey no-reading bar, and the two must not
  // contradict each other on the operator's screen.
  const percent = model.percent === null ? "—" : `${Math.round(model.percent)}%`;
  context.font = "700 22px sans-serif";
  const percentWidth = rightText(context, percent, right, 30, model.percent === null ? MUTED : TEXT);
  context.font = "700 21px sans-serif";
  context.fillStyle = TEXT;
  context.fillText(fit(context, model.title, right - left - percentWidth - 14), left, 30);

  let cursor = left;
  if (model.activity !== null) {
    drawIcon(context, activityFragment(model.activity.glyph), cursor, 46, 16, accent);
    cursor += 21;
    context.font = "700 14px sans-serif";
    context.fillStyle = TEXT;
    context.fillText(model.activity.label, cursor, 59);
    cursor += context.measureText(model.activity.label).width + 12;
  }
  // The elapsed run is measured first so the status — a free string off the
  // wire, which an unknown bucket passes through verbatim — gets a real budget
  // and cannot overprint it on this shared baseline.
  context.font = "700 10px monospace";
  const captionWidth = model.elapsedLabel === null ? 0 : context.measureText("ELAPSED").width;
  context.font = "700 12px monospace";
  const elapsedWidth = model.elapsedLabel === null ? 0 : context.measureText(model.elapsedLabel).width + captionWidth + 20;
  context.fillStyle = accent;
  context.fillText(fit(context, bucket?.label.toUpperCase() ?? model.status.toUpperCase(), right - elapsedWidth - cursor), cursor, 59);

  if (model.elapsedLabel !== null) {
    context.font = "700 12px monospace";
    rightText(context, model.elapsedLabel, right, 59, MUTED);
    caption(context, "elapsed", right - context.measureText(model.elapsedLabel).width - 8 - captionWidth, 59);
  }

  if (model.percent === null) {
    // The same uninterrupted neutral fill the key face uses for a reading
    // nobody took.
    context.beginPath();
    context.roundRect(left, 74, right - left, 10, 5);
    context.fillStyle = UNKNOWN_PROGRESS_COLOR;
    context.fill();
    return;
  }
  // A measured 0% is a solid stub. The unknown branch above remains a full
  // neutral bar, so the strip makes the same no-reading/zero distinction as the key.
  meter(context, left, 74, right - left, model.percent / 100, progressBarColor(model.percent), 10, true);
};

/* Voice panel geometry. The trace is the panel; everything else sits around it. */
/** Width of the vertical decibel bar on the right edge. */
const DB_BAR_WIDTH = 16;
/** Top and bottom of the decibel bar and of the waveform band. */
const TRACE_TOP = 10;
const TRACE_BOTTOM = 62;
/** Baseline for the status caption and the transcribed text. */
const VOICE_STATUS_BASELINE = 78;
const VOICE_TEXT_BASELINE = 94;
/** Gap between the waveform's right edge and the decibel bar. */
const TRACE_GAP = 14;
/** Minimum drawn height of one waveform column, so silence is still a line. */
const MIN_COLUMN_HEIGHT = 1;
/** Trace colour while capturing, and while idle. */
const TRACE_LIVE = ACCENT_LIVE;
const TRACE_IDLE = "rgba(255,255,255,0.32)";
/** Status colour when transcription is unavailable — a state, not an error. */
const STATUS_WARN = "#ffb27a";

/**
 * The voice readout: waveform, decibel bar, transcribed text.
 *
 * **Both meters are local.** The columns and the dBFS reading were computed
 * from the captured PCM on this machine — see `voicePanel.ts` — so this panel
 * animates at capture latency whether or not Aiur is reachable, and whether or
 * not Aiur has an API key. Only `content.data.text` came back over the wire,
 * and it is drawn on its own line: a network stall leaves the text stale while
 * the trace keeps moving, which is exactly the distinction the operator needs.
 *
 * The trace scrolls left to right. `createWaveformScroll` emits oldest-first
 * and pre-fills silence, so column `i` maps straight to the `i`-th x position
 * and the newest audio is always the right-hand edge — no reversal, and a
 * full-width baseline from the first frame rather than a trace growing in.
 */
export const drawVoicePanel = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "voice" }): void => {
  const { data } = content;
  const barX = width - PAD - DB_BAR_WIDTH;
  const traceX = PAD;
  const traceWidth = barX - TRACE_GAP - traceX;
  const traceHeight = TRACE_BOTTOM - TRACE_TOP;
  const centerY = TRACE_TOP + traceHeight / 2;
  const halfHeight = traceHeight / 2;

  // Centre line, so a silent trace reads as silence rather than as nothing.
  context.fillStyle = "rgba(255,255,255,0.10)";
  context.fillRect(traceX, centerY - 0.5, traceWidth, 1);

  const columnWidth = traceWidth / data.columns.length;
  context.fillStyle = data.holding ? TRACE_LIVE : TRACE_IDLE;
  data.columns.forEach((column, index) => {
    // Drawn from the min/max pair rather than from one magnitude: a rectified
    // trace is a solid blob, while peaks above and valleys below the centre
    // read as speech.
    const top = centerY - clamp(column.max, -1, 1) * halfHeight;
    const bottom = centerY - clamp(column.min, -1, 1) * halfHeight;
    context.fillRect(traceX + index * columnWidth, top, Math.max(columnWidth - 0.5, 0.5), Math.max(bottom - top, MIN_COLUMN_HEIGHT));
  });

  // Vertical decibel bar. `fill` is already linear in decibels (`dbfsToFill`),
  // so it is used as a height directly — re-mapping it to amplitude here would
  // undo the whole reason that mapping exists.
  const barHeight = TRACE_BOTTOM - TRACE_TOP;
  context.beginPath();
  context.roundRect(barX, TRACE_TOP, DB_BAR_WIDTH, barHeight, DB_BAR_WIDTH / 2);
  context.fillStyle = TRACK;
  context.fill();
  const filled = Math.round(barHeight * clamp(data.fill, 0, 1));
  if (filled > 0) {
    context.beginPath();
    context.roundRect(barX, TRACE_BOTTOM - filled, DB_BAR_WIDTH, filled, DB_BAR_WIDTH / 2);
    context.fillStyle = createPaint(context, "linear-gradient(0deg,#37d97e,#e0564e)", barX, TRACE_TOP, DB_BAR_WIDTH, barHeight);
    context.fill();
  }
  context.font = "700 9px monospace";
  context.fillStyle = LABEL;
  const dbText = `${Math.round(data.dbfs)}`;
  context.fillText(dbText, barX + (DB_BAR_WIDTH - context.measureText(dbText).width) / 2, HEIGHT - 8);

  // The status line is the one place the unavailable reason can appear, and it
  // is deliberately beside a moving trace: "transcription is off" must not look
  // like "the microphone is dead".
  const unavailable = !data.holding && data.status !== VOICE_HOLD_PROMPT && data.status !== VOICE_LISTENING;
  caption(context, data.status, PAD, VOICE_STATUS_BASELINE, unavailable ? STATUS_WARN : data.holding ? ACCENT_LIVE : LABEL);

  context.font = CHAT_BODY_FONT;
  context.fillStyle = data.text === "" ? OPENCODE.textMuted : TEXT;
  const placeholder = data.holding ? "Listening…" : "Nothing heard yet.";
  context.fillText(fit(context, data.text === "" ? placeholder : data.text, width - PAD * 2), PAD, VOICE_TEXT_BASELINE);
};

/**
 * The settings readout: which microphone is in use, how many were found, and
 * what the two non-microphone keys do.
 *
 * A machine with no microphone is a normal state, not a fault — `pw-dump` and
 * `pactl` are both absent on a headless box, and `listMicrophones` returns an
 * empty list rather than throwing. It gets its own line so the surface says
 * what is true instead of showing an empty selection that reads as broken.
 */
export const drawSettingsPanel = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "settings" }): void => {
  caption(context, "microphone", PAD, 22);

  const none = content.deviceCount === 0;
  context.font = "700 22px sans-serif";
  context.fillStyle = none ? MUTED : TEXT;
  context.fillText(fit(context, none ? "No microphones" : content.selectedLabel, width - PAD * 2), PAD, 50);

  context.font = "700 12px monospace";
  context.fillStyle = LABEL;
  const found = none
    ? "Attach a microphone, then reopen settings"
    : `${content.deviceCount} found · page ${content.pageLabel}`;
  context.fillText(fit(context, found, width - PAD * 2), PAD, 70);

  drawHint(context, "BACK", PAD, HEIGHT - 6, true, false);
  context.font = "700 9px monospace";
  context.fillStyle = none ? LABEL : ACCENT_LIVE;
  const hint = "HOLD TESTMIC TO CHECK LEVELS";
  context.fillText(hint, width - PAD - context.measureText(hint).width, HEIGHT - 6);
};

/** Amber used for an answerable (OPEN) Command's status. */
export const OPEN_AMBER = "#ffcf87";
/** Green used for the Approve affordance — the one strip element that commits. */
const APPROVE_GREEN = ACCENT_LIVE;
/** Red used for a Commands error: a failed page load or a refused answer. */
export const COMMANDS_ERROR = "#e06c75";

/**
 * The Commands page readout: a full-width Command question with its reading
 * and status, and — when an answer is armed — the unmistakable green APPROVE
 * label.
 */
export const drawCommandsPanel = (context: SKRSContext2D, width: number, content: SegmentContent & { kind: "commands" }): void => {
  const model: CommandsPanelModel = content.model;
  const right = width - PAD;

  // A channel error (a refused answer, a failed page) is shown instead of the
  // reading: silently doing nothing after a deliberate approve action is worse
  // than a loud failure the operator can see.
  if (model.error !== undefined && model.error !== null && model.error !== "") {
    caption(context, "ERROR", PAD, 22, COMMANDS_ERROR);
    context.font = "700 18px sans-serif";
    context.fillStyle = COMMANDS_ERROR;
    context.fillText(fit(context, model.error, width - PAD * 2), PAD, 46);
    drawHint(context, "BACK", PAD, HEIGHT - 6, true, false);
    return;
  }

  if (model.view === "history") {
    caption(context, "commands", PAD, 22);
    context.font = "700 22px sans-serif";
    context.fillStyle = TEXT;
    context.fillText(fit(context, model.description, width - PAD * 2 - 120), PAD, 50);

    context.font = "700 12px monospace";
    context.fillStyle = model.activeCount === 0 ? LABEL : OPEN_AMBER;
    const count = `${model.activeCount} open`;
    const page = model.page === "" ? "" : ` · page ${model.page}`;
    context.fillText(count, PAD, 72);
    context.fillText(page, PAD + context.measureText(count).width, 72);

    drawHint(context, "BACK", PAD, HEIGHT - 6, true, false);
    context.font = "700 9px monospace";
    context.fillStyle = LABEL;
    const hint = "PRESS A KEY TO READ IT";
    context.fillText(hint, right - context.measureText(hint).width, HEIGHT - 6);
    return;
  }

  // Detail: the question, the reading, the status, and the approval state.
  const statusColour = model.answerable ? OPEN_AMBER : APPROVE_GREEN;
  caption(context, model.status, PAD, 22, statusColour);
  context.font = "700 9px monospace";
  context.fillStyle = LABEL;
  context.textAlign = "right";
  context.fillText(fit(context, model.ticketId, 180), right, 22);
  context.textAlign = "left";

  context.font = "700 20px sans-serif";
  context.fillStyle = TEXT;
  context.fillText(fit(context, model.title, width - PAD * 2), PAD, 46);

  context.font = "600 14px sans-serif";
  context.fillStyle = MUTED;
  context.fillText(fit(context, model.description, width - PAD * 2), PAD, 64);

  if (model.recorded !== null) {
    // Read-only: what was decided, with no Approve affordance on a settled Command.
    context.font = "700 12px monospace";
    context.fillStyle = APPROVE_GREEN;
    context.fillText(fit(context, model.recorded, width - PAD * 2), PAD, 82);
    drawHint(context, "BACK", PAD, HEIGHT - 6, true, false);
    return;
  }

  // Answerable: the green approval affordance when an answer is armed, or the
  // path hint. The approve state must be unmistakable — it commits a durable
  // operator decision that a normal dial does not.
  drawHint(context, "BACK", PAD, HEIGHT - 6, true, false);
  context.font = "700 11px monospace";
  if (model.approving) {
    context.fillStyle = APPROVE_GREEN;
    const label = "DIAL D · APPROVE";
    context.fillText(label, right - context.measureText(label).width, HEIGHT - 6);
  } else {
    context.fillStyle = LABEL;
    const hint = "READ AN OPTION OR HOLD MIC";
    context.fillText(hint, right - context.measureText(hint).width, HEIGHT - 6);
  }
};

/** Renders one panel's content onto a `width` x 100 context. */

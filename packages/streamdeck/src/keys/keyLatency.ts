/**
 * Key-write latency harness — an internal benchmark, deliberately NOT part of
 * the package's public surface (`index.ts` does not re-export it).
 *
 * It isolates the key-image encoding path this package owns — building the
 * `0x07` report sequence — and compares a single-key update against a full
 * eight-key panel repaint. Canvas rasterisation (#1355 device path) and the
 * hidraw USB transfer (#1354) are additive on top; because USB write
 * throughput dominates, the **report count** reported here is the meaningful
 * proxy for on-device repaint cost (one report ≈ one ~1KB USB transfer). It
 * exists to back the ticket's full-panel-repaint-latency acceptance with a
 * real, reproducible number and to let CI re-measure the regression later.
 */
import { KEY_COUNT, buildKeyImageReports } from "./keyImage.js";

/** Timing and transfer counts for {@link measureKeyRepaintLatency}. */
export interface KeyRepaintLatency {
  /** Wall-clock to build the report sequence for a single key, in ms. */
  readonly singleKeyMs: number;
  /** Wall-clock to build report sequences for all eight keys, in ms. */
  readonly fullPanelMs: number;
  /** Reports (≈ USB transfers) produced for a single-key write. */
  readonly singleKeyReports: number;
  /** Reports (≈ USB transfers) produced across a full eight-key repaint. */
  readonly fullPanelReports: number;
}

/**
 * Measure the report-building cost of a single-key update versus a full
 * eight-key repaint, using a representative per-key JPEG size.
 *
 * `now` is injected (default `performance.now`) so tests can supply a
 * deterministic clock.
 */
export function measureKeyRepaintLatency(
  jpegBytesPerKey: number,
  iterations = 1000,
  now: () => number = () => performance.now(),
): KeyRepaintLatency {
  const jpeg = new Uint8Array(Math.max(0, Math.floor(jpegBytesPerKey)));

  const singleStart = now();
  let singleReports = 0;
  for (let i = 0; i < iterations; i += 1) {
    singleReports = buildKeyImageReports(0, jpeg).length;
  }
  const singleKeyMs = (now() - singleStart) / iterations;

  const fullStart = now();
  let fullReports = 0;
  for (let i = 0; i < iterations; i += 1) {
    fullReports = 0;
    for (let index = 0; index < KEY_COUNT; index += 1) {
      fullReports += buildKeyImageReports(index, jpeg).length;
    }
  }
  const fullPanelMs = (now() - fullStart) / iterations;

  return {
    singleKeyMs,
    fullPanelMs,
    singleKeyReports: singleReports,
    fullPanelReports: fullReports,
  };
}

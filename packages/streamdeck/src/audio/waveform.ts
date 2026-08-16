/**
 * Rolling waveform reduction for the TestMic panel.
 *
 * Capture delivers far more samples than the panel has pixel columns, so the
 * stream is reduced to one min/max pair per column. Keeping the pair rather
 * than a single magnitude is what makes the display read as peaks *and*
 * valleys instead of a rectified blob.
 *
 * Pure and clock-free: the scroll advances on sample volume, never on a timer,
 * so tests drive it with fixed arrays.
 */

/** Vertical extent of one drawn column, each in -1..1. */
export interface WaveformColumn {
  readonly min: number;
  readonly max: number;
}

const SILENT_COLUMN: WaveformColumn = Object.freeze({ min: 0, max: 0 });

export interface WaveformScroll {
  /** Folds more samples in, emitting columns as each fills. */
  push(samples: Float32Array): void;
  /**
   * The visible window, oldest first. The newest audio is the right-hand
   * column, so the trace travels left to right as the operator speaks.
   */
  columns(): readonly WaveformColumn[];
  /** Drops all history, for when capture restarts on a different device. */
  reset(): void;
}

/**
 * @param width          number of columns the panel can draw
 * @param samplesPerColumn how many samples each column condenses
 */
export function createWaveformScroll(width: number, samplesPerColumn: number): WaveformScroll {
  if (width <= 0) throw new Error("waveform width must be positive");
  if (samplesPerColumn <= 0) throw new Error("waveform samplesPerColumn must be positive");

  // Pre-filled with silence so the panel has a full-width baseline from the
  // first frame rather than growing in from the left.
  let visible: WaveformColumn[] = new Array<WaveformColumn>(width).fill(SILENT_COLUMN);
  let pending = 0;
  let min = 0;
  let max = 0;

  const commit = (): void => {
    visible.push({ min, max });
    visible.shift();
    pending = 0;
    min = 0;
    max = 0;
  };

  return {
    push(samples: Float32Array): void {
      for (const sample of samples) {
        if (pending === 0) {
          min = sample;
          max = sample;
        } else {
          if (sample < min) min = sample;
          if (sample > max) max = sample;
        }
        pending += 1;
        if (pending === samplesPerColumn) commit();
      }
    },
    columns(): readonly WaveformColumn[] {
      return visible;
    },
    reset(): void {
      visible = new Array<WaveformColumn>(width).fill(SILENT_COLUMN);
      pending = 0;
      min = 0;
      max = 0;
    },
  };
}

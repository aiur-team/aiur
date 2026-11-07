export const toPcm16Sample = (sample: number): number => {
  const clamped = Math.max(-1, Math.min(1, sample));
  return Math.round(clamped < 0 ? clamped * 32_768 : clamped * 32_767);
};

export class Pcm16Downsampler {
  readonly #step: number;
  #position = 0;
  #tail: number | undefined;

  constructor(sourceRateHz: number, readonly targetRateHz: number) {
    if (sourceRateHz <= 0 || targetRateHz <= 0 || targetRateHz > sourceRateHz) {
      throw new RangeError("PCM sample rates must be positive and the target cannot exceed the source");
    }
    this.#step = sourceRateHz / targetRateHz;
  }

  push(samples: Float32Array): Int16Array {
    if (samples.length === 0) return new Int16Array();
    if (this.#step === 1) return Int16Array.from(samples, toPcm16Sample);

    const input = this.withTail(samples);
    const output: number[] = [];
    while (this.#position < input.length - 1) {
      output.push(toPcm16Sample(interpolate(input, this.#position)));
      this.#position += this.#step;
    }
    this.#position -= input.length - 1;
    this.#tail = input[input.length - 1];
    return Int16Array.from(output);
  }

  private withTail(samples: Float32Array): Float32Array {
    if (this.#tail === undefined) return samples;
    const input = new Float32Array(samples.length + 1);
    input[0] = this.#tail;
    input.set(samples, 1);
    return input;
  }
}

const interpolate = (samples: Float32Array, position: number): number => {
  const before = Math.floor(position);
  const fraction = position - before;
  return samples[before]! + (samples[before + 1]! - samples[before]!) * fraction;
};

class AiurVoiceCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.chunks = [];
    this.sampleCount = 0;
    this.targetSamples = Math.max(128, Math.round(sampleRate / 20));
  }

  process(inputs) {
    const input = inputs[0]?.[0];
    if (!input?.length) return true;

    this.chunks.push(new Float32Array(input));
    this.sampleCount += input.length;

    if (this.sampleCount >= this.targetSamples) {
      const samples = new Float32Array(this.sampleCount);
      let offset = 0;
      for (const chunk of this.chunks) {
        samples.set(chunk, offset);
        offset += chunk.length;
      }

      this.port.postMessage({ samples, sampleRate }, [samples.buffer]);
      this.chunks = [];
      this.sampleCount = 0;
    }

    return true;
  }
}

registerProcessor("aiur-voice-capture", AiurVoiceCaptureProcessor);

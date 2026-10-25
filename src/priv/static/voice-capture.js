(() => {
  const TARGET_SAMPLE_RATE = 16000;
  const DEVICE_STORAGE_KEY = "aiur-dashboard-microphone-device";
  const WAVEFORM_COLUMNS = 120;
  const SAMPLES_PER_COLUMN = 800;

  function requestMicrophone(deviceId) {
    const audio = deviceId ? { deviceId: { exact: deviceId } } : true;
    return navigator.mediaDevices.getUserMedia({ audio });
  }

  async function listMicrophones() {
    return (await navigator.mediaDevices.enumerateDevices()).filter((item) => item.kind === "audioinput");
  }

  function rememberDevice(deviceId) {
    try {
      window.localStorage.setItem(DEVICE_STORAGE_KEY, deviceId || "");
    } catch (_error) {}
  }

  function recalledDevice() {
    try {
      return window.localStorage.getItem(DEVICE_STORAGE_KEY) || "";
    } catch (_error) {
      return "";
    }
  }

  function downsample(input, sourceRate, targetRate) {
    if (sourceRate === targetRate) return input;
    const outputLength = Math.max(1, Math.round(input.length * targetRate / sourceRate));
    const output = new Float32Array(outputLength);
    const ratio = sourceRate / targetRate;
    for (let index = 0; index < outputLength; index += 1) {
      const start = Math.floor(index * ratio);
      const end = Math.max(start + 1, Math.min(input.length, Math.floor((index + 1) * ratio)));
      let total = 0;
      for (let cursor = start; cursor < end; cursor += 1) total += input[cursor];
      output[index] = total / (end - start);
    }
    return output;
  }

  // The voice socket expects 16 kHz mono PCM16, little-endian, base64-encoded.
  function encodePcm16Base64(samples) {
    const pcm = new Uint8Array(samples.length * 2);
    const view = new DataView(pcm.buffer);
    samples.forEach((sample, index) => {
      const bounded = Math.max(-1, Math.min(1, sample));
      view.setInt16(index * 2, bounded < 0 ? bounded * 32768 : bounded * 32767, true);
    });
    let binary = "";
    for (const byte of pcm) binary += String.fromCharCode(byte);
    return window.btoa(binary);
  }

  class WaveformBuffer {
    constructor() {
      this.reset();
    }

    reset() {
      this.columns = new Array(WAVEFORM_COLUMNS).fill(null).map(() => ({ min: 0, max: 0 }));
      this.pending = [];
    }

    push(samples) {
      for (const sample of samples) {
        this.pending.push(sample);
        if (this.pending.length !== SAMPLES_PER_COLUMN) continue;
        this.columns.push({ min: Math.min(...this.pending), max: Math.max(...this.pending) });
        this.columns.shift();
        this.pending = [];
      }
    }
  }

  // Owns a granted microphone stream and the AudioWorklet graph that reads it.
  // onSamples receives 16 kHz Float32 chunks.
  class Capture {
    constructor(stream, onSamples) {
      this.stream = stream;
      this.onSamples = onSamples;
    }

    async start(isCurrent = () => true) {
      if (this.stopped) return;
      const context = new window.AudioContext();
      this.context = context;
      await context.resume();
      if (!isCurrent()) return;
      await context.audioWorklet.addModule("/voice-capture-worklet.js");
      if (!isCurrent()) return;
      const source = context.createMediaStreamSource(this.stream);
      const worklet = new window.AudioWorkletNode(context, "aiur-voice-capture");
      const mute = context.createGain();
      mute.gain.value = 0;
      source.connect(worklet).connect(mute).connect(context.destination);
      worklet.port.onmessage = (event) => this.handleSamples(event.data);
      this.source = source;
      this.worklet = worklet;
      this.mute = mute;
    }

    handleSamples(payload) {
      if (!payload?.samples || !payload?.sampleRate) return;
      const samples = downsample(payload.samples, payload.sampleRate, TARGET_SAMPLE_RATE);
      if (samples.length) this.onSamples(samples);
    }

    stop() {
      this.stopped = true;
      this.worklet?.disconnect();
      this.source?.disconnect();
      this.mute?.disconnect();
      this.stream?.getTracks().forEach((track) => track.stop());
      this.context?.close();
      this.worklet = this.source = this.mute = this.stream = this.context = null;
    }
  }

  window.AiurVoiceCapture = {
    Capture,
    WaveformBuffer,
    downsample,
    encodePcm16Base64,
    listMicrophones,
    recalledDevice,
    rememberDevice,
    requestMicrophone
  };
})();

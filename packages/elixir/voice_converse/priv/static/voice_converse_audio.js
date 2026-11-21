export const PCM_RATE = 16_000;

export const WORKLET_SOURCE = `class VoiceCaptureProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const channel = inputs[0]?.[0];
    if (channel) this.port.postMessage(channel.slice());
    return true;
  }
}
registerProcessor("voice-capture", VoiceCaptureProcessor);`;

export function resamplePcm16(samples, sourceRate, targetRate) {
  const outputLength = Math.max(1, Math.round((samples.length * targetRate) / sourceRate));
  const output = new Int16Array(outputLength);
  for (let index = 0; index < outputLength; index += 1) {
    const position = (index * sourceRate) / targetRate;
    const left = Math.floor(position);
    const right = Math.min(left + 1, samples.length - 1);
    const sample = samples[left] + (samples[right] - samples[left]) * (position - left);
    output[index] = Math.max(-1, Math.min(1, sample)) * 32767;
  }
  return output;
}

export function bytesToBase64(bytes) {
  let text = "";
  bytes.forEach((byte) => (text += String.fromCharCode(byte)));
  return btoa(text);
}

export function base64ToBytes(value) {
  const text = atob(value);
  return Uint8Array.from(text, (character) => character.charCodeAt(0));
}

export function graphemeLength(text) {
  return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)].length;
}

export function sliceGraphemes(text, length) {
  return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)]
    .slice(0, length)
    .map((part) => part.segment)
    .join("");
}

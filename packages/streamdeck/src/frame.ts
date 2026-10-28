import { createCanvas, loadImage, GlobalFonts } from "@napi-rs/canvas";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { HidBackend } from "./backend.js";
import { KeyCache } from "./keys/keyCache.js";
import { BLACK } from "./keys/keyFill.js";
import { KeyWriteQueue } from "./keys/writeQueue.js";
import { PanelCache } from "./touchStrip/panelCache.js";

export interface FrameImage { readonly svg: string; readonly hash: string; readonly label?: string }
export interface DeckFrame {
  readonly keys: readonly (FrameImage | null)[];
  readonly strip: readonly (FrameImage & { readonly x: number; readonly width: number })[];
}

export function registerFrameFont(): void {
  const font = fileURLToPath(new URL("../assets/JetBrainsMono-Variable.woff2", import.meta.url));
  if (!GlobalFonts.registerFromPath(font, "JetBrains Mono")) throw new Error("Cannot register JetBrains Mono");
}

export function offlineFrame(): DeckFrame {
  return { keys: Array(8).fill(null), strip: [{ x: 0, width: 800, hash: "offline", svg: readFileSync(new URL("../assets/offline.svg", import.meta.url), "utf8") }] };
}

/** Serializes complete frames; cache state is committed only after device writes. */
export class FrameRenderer {
  private backend: HidBackend | null = null;
  private readonly keys = new KeyCache();
  private readonly panels = new PanelCache();
  private keyHashes: (string | null)[] = [];
  private stripHashes: string[] = [];
  private readonly jpegs = new Map<string, Buffer>();
  private chain: Promise<void> = Promise.resolve();

  constructor(private readonly capacity = 128) {}

  invalidate(): void {
    this.keyHashes = [];
    this.stripHashes = [];
    this.keys.invalidate();
    this.panels.invalidate();
  }

  apply(backend: HidBackend, frame: DeckFrame): Promise<void> {
    const next = this.chain.then(() => this.paint(backend, frame));
    this.chain = next.catch(() => undefined);
    return next;
  }

  private async jpeg(image: FrameImage, width: number, height: number): Promise<Buffer> {
    const key = `${width}:${height}:${image.hash}`;
    let jpeg = this.jpegs.get(key);
    this.jpegs.delete(key);
    if (jpeg === undefined) {
      const canvas = createCanvas(width, height);
      const decoded = await loadImage(Buffer.from(image.svg));
      canvas.getContext("2d").drawImage(decoded, 0, 0, width, height);
      jpeg = canvas.toBuffer("image/jpeg", 90);
    }
    this.jpegs.set(key, jpeg);
    if (this.jpegs.size > this.capacity) this.jpegs.delete(this.jpegs.keys().next().value!);
    return jpeg;
  }

  private async paint(backend: HidBackend, frame: DeckFrame): Promise<void> {
    if (frame.keys.length !== 8) throw new Error("Frame must contain eight keys");
    let edge = 0;
    for (const region of frame.strip) {
      if (!Number.isInteger(region.x) || !Number.isInteger(region.width) || region.x !== edge || region.width <= 0) throw new Error("Frame strip must tile 800 pixels");
      edge += region.width;
    }
    if (edge !== 800) throw new Error("Frame strip must tile 800 pixels");
    if (backend !== this.backend) {
      this.backend = backend;
      this.invalidate();
    }
    const queue = new KeyWriteQueue(async (report) => {
      if (report.kind === "feature") await backend.sendFeatureReport(report.data);
      else await backend.write(report.data);
    });
    try {
      for (const [index, image] of frame.keys.entries()) {
        const hash = image?.hash ?? null;
        if (this.keyHashes[index] === hash) continue;
        const content = image === null ? { kind: "fill" as const, color: BLACK } : { kind: "image" as const, jpeg: await this.jpeg(image, 120, 120) };
        const paint = this.keys.paint(index, content);
        if (paint !== null) await queue.enqueue(paint);
      }
      const hashes = frame.strip.map((region) => `${region.x}:${region.width}:${region.hash}`);
      const layoutChanged = frame.strip.length !== this.stripHashes.length || frame.strip.some((region, index) => !this.stripHashes[index]?.startsWith(`${region.x}:${region.width}:`));
      if (layoutChanged) this.panels.invalidate();
      for (const [index, region] of frame.strip.entries()) {
        if (!layoutChanged && hashes[index] === this.stripHashes[index]) continue;
        const reports = this.panels.paint({ region: { x: region.x, y: 0, width: region.width, height: 100 }, jpeg: await this.jpeg(region, region.width, 100) });
        if (reports !== null) for (const report of reports) await backend.write(report);
      }
      this.keyHashes = frame.keys.map((image) => image?.hash ?? null);
      this.stripHashes = hashes;
    } catch (error) {
      this.invalidate();
      throw error;
    }
  }
}

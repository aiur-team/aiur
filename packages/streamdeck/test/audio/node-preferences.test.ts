import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createFilePreferenceStore, type FileSystemPort } from "../../src/audio/node-preferences.js";

const PATH = "/etc/aiur/streamdeck/mic.json";

/** In-memory filesystem, so the degradation paths are reachable without a disk. */
const fsHarness = (
  contents: string | Error,
): FileSystemPort & { written: [string, string][]; made: string[] } => {
  const written: [string, string][] = [];
  const made: string[] = [];
  return {
    written,
    made,
    readFileSync: () => {
      if (contents instanceof Error) throw contents;
      return contents;
    },
    writeFileSync: (path, data) => {
      written.push([path, data]);
    },
    mkdirSync: (path) => {
      made.push(path);
    },
  };
};

describe("file-backed preference store: reading", () => {
  it("returns the remembered device id", () => {
    const store = createFilePreferenceStore(PATH, fsHarness('{"deviceId":"alsa_input.yeti"}'));
    expect(store.read()).toBe("alsa_input.yeti");
  });

  it("reads the path it was constructed with", () => {
    const fs = fsHarness('{"deviceId":"alsa_input.yeti"}');
    const spy = vi.spyOn(fs, "readFileSync");
    createFilePreferenceStore(PATH, fs).read();
    expect(spy).toHaveBeenCalledWith(PATH);
  });

  it("reports no choice on a missing file, which is simply the first run", () => {
    const store = createFilePreferenceStore(PATH, fsHarness(new Error("ENOENT")));
    expect(store.read()).toBeNull();
  });

  it("reports no choice rather than throwing on unparseable JSON", () => {
    // A truncated write must cost one click, not the sidecar's startup.
    const store = createFilePreferenceStore(PATH, fsHarness("{not json"));
    expect(store.read()).toBeNull();
  });

  it("reports no choice when the document is valid JSON but not an object", () => {
    expect(createFilePreferenceStore(PATH, fsHarness('"alsa_input.yeti"')).read()).toBeNull();
    expect(createFilePreferenceStore(PATH, fsHarness("42")).read()).toBeNull();
  });

  it("reports no choice when the document is JSON null", () => {
    // `typeof null` is "object", so null needs its own guard.
    expect(createFilePreferenceStore(PATH, fsHarness("null")).read()).toBeNull();
  });

  it("reports no choice when deviceId is absent", () => {
    expect(createFilePreferenceStore(PATH, fsHarness('{"volume":3}')).read()).toBeNull();
  });

  it("reports no choice when deviceId is not a string", () => {
    expect(createFilePreferenceStore(PATH, fsHarness('{"deviceId":7}')).read()).toBeNull();
  });

  it("reports no choice when deviceId is empty, never an empty source name", () => {
    // "" would otherwise be handed to the recorder as a device to open.
    expect(createFilePreferenceStore(PATH, fsHarness('{"deviceId":""}')).read()).toBeNull();
  });
});

describe("file-backed preference store: writing", () => {
  it("creates the parent directory before writing, for a fresh machine", () => {
    const fs = fsHarness("");
    createFilePreferenceStore(PATH, fs).write("alsa_input.yeti");

    expect(fs.made).toEqual(["/etc/aiur/streamdeck"]);
    expect(fs.written).toEqual([[PATH, '{"deviceId":"alsa_input.yeti"}\n']]);
  });
});

describe("file-backed preference store: the default port", () => {
  const temporaries: string[] = [];
  const temporaryDir = (): string => {
    const dir = mkdtempSync(join(tmpdir(), "aiur-mic-"));
    temporaries.push(dir);
    return dir;
  };

  afterEach(() => {
    for (const dir of temporaries.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it("is wired to node:fs, so a real restart remembers the choice", () => {
    // The injected port makes the logic testable; only a round trip through a
    // real directory proves the default one actually reaches a disk.
    const path = join(temporaryDir(), "nested", "mic.json");
    const store = createFilePreferenceStore(path);

    expect(store.read()).toBeNull();
    store.write("alsa_input.yeti");

    expect(JSON.parse(readFileSync(path, "utf8"))).toEqual({ deviceId: "alsa_input.yeti" });
    expect(createFilePreferenceStore(path).read()).toBe("alsa_input.yeti");
  });
});

import { afterEach, expect, it, vi } from "vitest";
import { createPhysicalSurface } from "../src/surface.js";
import { StripRenderer } from "../src/touchStrip/stripRenderer.js";
import type { StreamDeckGrid } from "../src/channel-types.js";

afterEach(() => vi.restoreAllMocks());
it("uses Build counts for strip text while retaining backlog paging", async () => {
  const render = vi.spyOn(StripRenderer.prototype, "render").mockReturnValue([]);
  const surface = createPhysicalSurface();
  const backend = { write: vi.fn(), sendFeatureReport: vi.fn() } as never;
  const grid: StreamDeckGrid = { agents: [], total: 543, windows: 68, max_column_offset: 268,
    counts: { status: "ok", observed_at: 123, agents: 3, live: 2, queued: 5, not_queued: 2, by_state: { active: 2, ci_wait: 1 } } };
  await surface.repaint(backend, grid);
  expect(render.mock.lastCall?.[0]).toMatchObject({ mode: "grid", data: {
    summary: { live: 2, remaining: 5 }, pagerLabel: "3 agents · 5 queued", pager: { windowCount: 68 },
  } });
  await surface.repaint(backend, { ...grid, counts: undefined });
  expect(render.mock.lastCall?.[0]).toMatchObject({ data: { pagerLabel: "— agents", summary: { live: null, remaining: null } } });
  await surface.repaint(backend, { ...grid, counts: { ...grid.counts!, status: "stale" } });
  expect(render.mock.lastCall?.[0]).toMatchObject({ data: { summary: { live: 2, counts_status: "stale" } } });
});

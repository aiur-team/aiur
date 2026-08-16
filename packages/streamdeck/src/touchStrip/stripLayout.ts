/**
 * Touch-strip mode layouts — what the strip shows in each mode, and over which
 * rectangle.
 *
 * The strip is one 800x100 LCD. It is *usually* modelled as four 200x100
 * regions (see `geometry.ts`) because that makes a provider tick or a pager dot
 * cheap to repaint, but that split is a project decision, not a hardware
 * boundary, and some content genuinely refuses it: a ticket title, a chat line,
 * a bar that has to read as one bar. So a mode composes into **panels** — a
 * region plus the content that fills it — and a mode is free to use one 800-wide
 * panel, four 200-wide ones, or a mix.
 *
 * Every layout tiles the full strip with no gaps and no overlap. That is what
 * lets the renderer's cache treat a layout change as "repaint everything" and
 * otherwise diff panel by panel (see `panelCache.ts`).
 *
 * Modes:
 *
 *   - `grid`: [Summary | provider(s) | Pager]. With exactly two providers the
 *     centre stays two 200-wide segments, which is the look this surface has
 *     always had. With three or more it becomes one 400x100 panel — the daemon
 *     emits a meter per configured provider family, and two fixed slots could
 *     only ever show two of them — scrolled by knob 2 when more providers are
 *     configured than the panel shows at once.
 *   - `cmd`:  one 800x100 panel reading like the agent's grid key: a summary
 *     column on the left, then the full title, a full-width bar, the
 *     percentage, elapsed time and the agent's activity.
 *   - `logs`: one 800x100 panel carrying five transcript rows — the agent's
 *     actual chat log, not a two-row peephole.
 *
 * Content stays a structured descriptor rather than pixels, so both the layout
 * choices and the per-panel diffing are testable without a canvas.
 */
import type { TranscriptRow } from "../channel.js";
import type { Region } from "../imageWriter/headerGenerator.js";
import type { AgentDetailModel } from "./agentDetail.js";
import { SegmentIndex, segmentRegion, spanRegion, STRIP_REGION } from "./geometry.js";
import type { PagerModel } from "./pagerSegment.js";
import { providerPanelModel, WIDE_PANEL_THRESHOLD, type ProviderPanelModel, type ProviderPanelRow } from "./providerPanel.js";
import type { SummaryModel } from "./summarySegment.js";

/** The three touch-strip modes. */
export type StripMode = "grid" | "cmd" | "logs";

/** Structured content for one panel; the encoder renders it to a JPEG. */
export type SegmentContent =
  | { readonly kind: "summary"; readonly model: SummaryModel }
  | { readonly kind: "provider"; readonly row: ProviderPanelRow }
  /**
   * `originX` is the panel's own left edge on the strip. A painter is handed
   * its width only, and this panel has to place a label over one specific
   * knob — which is a strip coordinate, not a panel one. Carrying it here keeps
   * the painter position-agnostic: move the panel and the label follows,
   * instead of the painter assuming where the layout put it.
   */
  | { readonly kind: "providers"; readonly model: ProviderPanelModel; readonly originX: number }
  | { readonly kind: "pager"; readonly title: string; readonly label: string; readonly model: PagerModel }
  | { readonly kind: "agentDetail"; readonly model: AgentDetailModel }
  | {
      readonly kind: "chatLog";
      readonly rows: readonly TranscriptRow[];
      readonly chatHasPrevious: boolean;
      readonly chatHasNext: boolean;
      readonly eventHasPrevious: boolean;
      readonly eventHasNext: boolean;
    }
  /** A panel with nothing to show; painted as bare background, not a label. */
  | { readonly kind: "blank" };

/** One panel: the strip rectangle it owns and what fills it. */
export interface StripPanel {
  readonly region: Region;
  readonly content: SegmentContent;
}

/** Data the `grid` mode needs. Every field is a real projection, not invented. */
export interface GridData {
  readonly summary: SummaryModel;
  /** One row per configured provider family, in display order. */
  readonly providers: readonly ProviderPanelRow[];
  readonly pager: PagerModel;
  /** Caption under the pager dots, e.g. a window range. */
  readonly pagerLabel: string;
  /** First provider row the merged panel shows; knob 2 moves it. */
  readonly providerOffset: number;
}

/** Data the `cmd` mode needs: the focused agent's whole readout. */
export interface CmdData {
  readonly detail: AgentDetailModel;
}

/** Data the `logs` mode needs: the visible transcript rows and the scroll hints. */
export interface LogsData {
  /**
   * The transcript window, structured rather than pre-rendered: the painter
   * needs the badge, the role and the diff counts to tell the three row shapes
   * apart.
   */
  readonly rows: readonly TranscriptRow[];
  readonly chatHasPrevious?: boolean;
  readonly chatHasNext?: boolean;
  readonly eventHasPrevious?: boolean;
  readonly eventHasNext?: boolean;
}

/** Discriminated per-mode data union passed to {@link composeStrip}. */
export type StripData =
  | { readonly mode: "grid"; readonly data: GridData }
  | { readonly mode: "cmd"; readonly data: CmdData }
  | { readonly mode: "logs"; readonly data: LogsData };

const BLANK: SegmentContent = { kind: "blank" };

/** The centre two segments as one 400x100 area. */
const WIDE_PROVIDER_REGION = spanRegion(SegmentIndex.Second, 2);

/**
 * The centre of the grid strip: two fixed segments, or one wide panel.
 *
 * Two is the case the strip was built for and keeps its exact geometry. Fewer
 * than two leaves the unused segment blank rather than printing an "Awaiting
 * data" panel for a provider that is not configured at all — the operator would
 * have no way to tell that apart from a provider whose meter is late.
 */
const providerPanels = (providers: readonly ProviderPanelRow[], offset: number): StripPanel[] => {
  if (providers.length >= WIDE_PANEL_THRESHOLD) {
    return [
      {
        region: WIDE_PROVIDER_REGION,
        content: { kind: "providers", model: providerPanelModel(providers, offset), originX: WIDE_PROVIDER_REGION.x },
      },
    ];
  }
  return [SegmentIndex.Second, SegmentIndex.Third].map((index, slot) => {
    const row = providers[slot];
    return {
      region: segmentRegion(index),
      content: row === undefined ? BLANK : { kind: "provider", row },
    };
  });
};

/**
 * Compose a mode into the panels that tile the strip, left to right. The
 * renderer encodes and diffs each one independently.
 */
export function composeStrip(input: StripData): readonly StripPanel[] {
  switch (input.mode) {
    case "grid": {
      const { summary, providers, pager, pagerLabel, providerOffset } = input.data;
      return [
        { region: segmentRegion(SegmentIndex.First), content: { kind: "summary", model: summary } },
        ...providerPanels(providers, providerOffset),
        { region: segmentRegion(SegmentIndex.Fourth), content: { kind: "pager", title: "MORE AGENTS", label: pagerLabel, model: pager } },
      ];
    }
    case "cmd":
      return [{ region: STRIP_REGION, content: { kind: "agentDetail", model: input.data.detail } }];
    case "logs":
      return [
        {
          region: STRIP_REGION,
          content: {
            kind: "chatLog",
            rows: input.data.rows,
            chatHasPrevious: input.data.chatHasPrevious === true,
            chatHasNext: input.data.chatHasNext === true,
            eventHasPrevious: input.data.eventHasPrevious === true,
            eventHasNext: input.data.eventHasNext === true,
          },
        },
      ];
  }
}

/**
 * The Build Order line-art icon set, drawn on canvas.
 *
 * The design mock renders each key's epic icon as an inline `<svg>` from
 * `BO_ICONS` (see `docs/design/streamdeck/README.md`). The shapes below are
 * those definitions **verbatim**, kept as their original SVG fragment strings
 * so a re-extraction from the mock is a copy-paste rather than a translation.
 * Every fragment is authored against a 24x24 viewBox and stroked, never filled.
 *
 * Only the four primitives the icon set actually uses are supported — `path`,
 * `circle`, `rect`, `ellipse`. A general SVG renderer would be far more code
 * for no additional coverage; an unknown element is skipped rather than
 * throwing, so adding one to the mock degrades to a missing shape instead of a
 * blank key.
 */
import { Path2D, type SKRSContext2D } from "@napi-rs/canvas";

/** Design viewBox every fragment is authored in. */
export const ICON_VIEWBOX = 24;

/** Stroke width the mock draws the Build Order icons at, in viewBox units. */
export const ICON_STROKE_WIDTH = 1.7;

/**
 * Build Order icons, keyed by the lane name the daemon sends as `icon`.
 * Verbatim from the design mock's `BO_ICONS`.
 */
export const BUILD_ORDER_ICONS: Readonly<Record<string, string>> = Object.freeze({
  repo: '<path d="M4 4h11l5 5v11H4z"/><path d="M15 4v5h5"/>',
  pipeline:
    '<circle cx="6" cy="6" r="2.4"/><circle cx="18" cy="18" r="2.4"/><path d="M8.4 6H16a2 2 0 0 1 2 2v7.6M6 8.4V16a2 2 0 0 0 2 2h7.6"/>',
  logs: '<path d="M5 4h14v16H5z"/><path d="M8 8h8M8 12h8M8 16h5"/>',
  palette:
    '<path d="M12 3a9 9 0 1 0 0 18c1.7 0 2-1.3 1.2-2.2-.8-.9-.5-2.3.8-2.3H17a4 4 0 0 0 4-4c0-4.6-4-7.5-9-7.5z"/><circle cx="7.5" cy="11" r="1"/><circle cx="12" cy="8" r="1"/><circle cx="16" cy="11" r="1"/>',
  database:
    '<ellipse cx="12" cy="6" rx="7" ry="3"/><path d="M5 6v12c0 1.7 3.1 3 7 3s7-1.3 7-3V6"/><path d="M5 12c0 1.7 3.1 3 7 3s7-1.3 7-3"/>',
  shield: '<path d="M12 3l7 3v5c0 4.6-3 8.4-7 10-4-1.6-7-5.4-7-10V6z"/><path d="m9 12 2 2 4-4"/>',
  key: '<circle cx="8" cy="8" r="4"/><path d="m11 11 8 8M16 16l2-2M18 18l2-2"/>',
  alert: '<path d="M12 4 3 20h18z"/><path d="M12 10v4M12 17h.01"/>',
  components:
    '<rect x="4" y="4" width="7" height="7" rx="1.4"/><rect x="13" y="4" width="7" height="7" rx="1.4"/><rect x="4" y="13" width="7" height="7" rx="1.4"/><rect x="13" y="13" width="7" height="7" rx="1.4"/>',
  cloud: '<path d="M7 18a4 4 0 0 1 0-8 5 5 0 0 1 9.6-1.3A3.8 3.8 0 0 1 18 18z"/>',
  retry:
    '<path d="M4 12a8 8 0 0 1 13.7-5.6L20 8"/><path d="M20 4v4h-4"/><path d="M20 12a8 8 0 0 1-13.7 5.6L4 16"/><path d="M4 20v-4h4"/>',
  list: '<path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/>',
  flow: '<circle cx="6" cy="6" r="2.2"/><circle cx="18" cy="6" r="2.2"/><circle cx="12" cy="18" r="2.2"/><path d="M6 8.2V12a2 2 0 0 0 2 2h1M18 8.2V12a2 2 0 0 1-2 2h-4"/>',
  book: '<path d="M5 4h9a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3z"/><path d="M17 7h2v13H8"/>',
  chart: '<path d="M4 4v16h16"/><path d="M8 16v-4M12 16V8M16 16v-6"/>',
  beaker: '<path d="M9 3h6M10 3v6l-5 9a2 2 0 0 0 1.8 3h10.4a2 2 0 0 0 1.8-3l-5-9V3"/><path d="M7.5 15h9"/>',
  gauge: '<path d="M4 16a8 8 0 0 1 16 0"/><path d="M12 16l4-4"/><circle cx="12" cy="16" r="1.3"/>',
  eye: '<path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6-10-6-10-6z"/><circle cx="12" cy="12" r="2.6"/>',
  pencil: '<path d="M4 20h4L19 9a2 2 0 0 0-3-3L5 17z"/><path d="M14 7l3 3"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.5 3 14 0 18M12 3c-3 3.5-3 14 0 18"/>',
  lock: '<rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
  bug: '<rect x="7" y="8" width="10" height="10" rx="5"/><path d="M12 3v3M7 11H3M21 11h-4M7 16l-3 2M17 16l3 2M9 6 7 4M15 6l2-2"/>',
});

/** Icon the mock falls back to for an unknown lane. */
export const DEFAULT_ICON = "list";

/** Resolves a lane name to its fragment, mirroring the mock's `boIcon`. */
export const iconFragment = (lane: string | null | undefined): string =>
  BUILD_ORDER_ICONS[lane ?? ""] ?? BUILD_ORDER_ICONS[DEFAULT_ICON];

const attribute = (element: string, name: string): number | undefined => {
  const match = new RegExp(`${name}="([-\\d.]+)"`).exec(element);
  return match === null ? undefined : Number.parseFloat(match[1]);
};

const ELEMENT_PATTERN = /<(path|circle|rect|ellipse)\b([^>]*)>/g;

/** Traces one SVG element onto `context`'s current path. */
const traceElement = (context: SKRSContext2D, kind: string, attrs: string): void => {
  if (kind === "path") {
    const data = /\bd="([^"]+)"/.exec(attrs);
    if (data !== null) {
      context.stroke(new Path2D(data[1]));
    }
    return;
  }

  context.beginPath();
  if (kind === "circle") {
    const cx = attribute(attrs, "cx") ?? 0;
    const cy = attribute(attrs, "cy") ?? 0;
    context.arc(cx, cy, attribute(attrs, "r") ?? 0, 0, Math.PI * 2);
  } else if (kind === "ellipse") {
    const cx = attribute(attrs, "cx") ?? 0;
    const cy = attribute(attrs, "cy") ?? 0;
    context.ellipse(cx, cy, attribute(attrs, "rx") ?? 0, attribute(attrs, "ry") ?? 0, 0, 0, Math.PI * 2);
  } else {
    const x = attribute(attrs, "x") ?? 0;
    const y = attribute(attrs, "y") ?? 0;
    const width = attribute(attrs, "width") ?? 0;
    const height = attribute(attrs, "height") ?? 0;
    const radius = attribute(attrs, "rx") ?? 0;
    context.roundRect(x, y, width, height, radius);
  }
  context.stroke();
};

/**
 * Draws `fragment` as a `size`-pixel square whose top-left corner is (`x`,
 * `y`), stroked in `color`. The 24-unit viewBox is scaled to `size`, and the
 * stroke width is scaled with it so the line weight matches the mock at any
 * size.
 */
export const drawIcon = (
  context: SKRSContext2D,
  fragment: string,
  x: number,
  y: number,
  size: number,
  color: string,
): void => {
  const scale = size / ICON_VIEWBOX;
  // save()/restore() covers the transform, but this canvas implementation does
  // not roll back stroke state with it, so capture and put those back by hand.
  // Leaking a stroke colour here would silently retint whatever the caller
  // draws next.
  const previousStroke = context.strokeStyle;
  const previousWidth = context.lineWidth;

  context.save();
  context.translate(x, y);
  context.scale(scale, scale);
  context.strokeStyle = color;
  context.lineWidth = ICON_STROKE_WIDTH;
  context.lineCap = "round";
  context.lineJoin = "round";

  for (const [, kind, attrs] of fragment.matchAll(ELEMENT_PATTERN)) {
    traceElement(context, kind, attrs);
  }

  context.restore();
  context.strokeStyle = previousStroke;
  context.lineWidth = previousWidth;
};

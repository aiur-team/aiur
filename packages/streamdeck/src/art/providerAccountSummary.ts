import type { SKRSContext2D } from "@napi-rs/canvas";

import { fit } from "./segmentText.js";

/** Account subject below the provider title in a narrow panel. */
export const drawAccountSummary = (
  context: SKRSContext2D,
  summaryLabel: string | undefined,
  x: number,
  y: number,
  maxWidth: number,
): void => {
  if (summaryLabel) {
    context.font = "700 12px sans-serif";
    context.fillText(fit(context, summaryLabel, maxWidth), x, y);
  }
};

/** A wide panel shares its reading line with the account subject. */
export const accountReadingText = (reading: string, summaryLabel: string | undefined): string =>
  summaryLabel ? `${reading} · ${summaryLabel.replace(" accounts", "")}` : reading;

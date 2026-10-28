/** The ticket page consumes Build evidence rather than the fleet grid bucket. */
import type { StreamDeckTicket } from "../channel.js";
import { agentDetailModel, type AgentDetailModel } from "./agentDetail.js";

export const ticketDetailModel = (ticket: StreamDeckTicket | null, identifier: string | null, now = Date.now()): AgentDetailModel => ({
  ...agentDetailModel({
    identifier: identifier ?? "—",
    title: ticket?.title,
    vendor: ticket?.agent?.model,
    progress_percent: ticket?.agent?.pct,
    runtime_seconds: ticket?.agent?.start == null ? null : Math.max(0, now - ticket.agent.start) / 1000,
  }),
  status: ticket?.status.label ?? "State unknown",
  buildStatus: true,
  prLabel: ticket?.pr == null ? null : `#${ticket.pr.num}${ticket.pr.ci == null ? "" : ` · ${ticket.pr.ci}`}`,
  observedAt: ticket?.observed_at ?? null,
});

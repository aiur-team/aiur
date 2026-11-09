import { Webhook } from "standardwebhooks";
import type { OutboundEvent } from "@aiur/contracts";

export interface WebhookIdStore {
  claim(webhookId: string): boolean;
}

export class DuplicateWebhookError extends Error {
  constructor(webhookId: string) {
    super(`Webhook ${webhookId} was already accepted`);
    this.name = "DuplicateWebhookError";
  }
}

export class InMemoryWebhookIdStore implements WebhookIdStore {
  readonly #seen = new Set<string>();

  claim(webhookId: string): boolean {
    if (this.#seen.has(webhookId)) return false;
    this.#seen.add(webhookId);
    return true;
  }
}

export function verifyAiurWebhook(
  rawBody: string | Buffer,
  headers: Record<string, string | undefined>,
  secret: string,
  idStore: WebhookIdStore,
): OutboundEvent {
  const normalizedHeaders = Object.fromEntries(
    Object.entries(headers).flatMap(([key, value]) => value === undefined ? [] : [[key.toLowerCase(), value]]),
  );
  const webhookId = normalizedHeaders["webhook-id"];
  const parsed = new Webhook(secret).verify(rawBody, normalizedHeaders);

  if (typeof webhookId !== "string" || !isRecord(parsed) || deliveryId(parsed) !== webhookId) {
    throw new Error("Signed webhook ID does not match the event body");
  }
  if (!idStore.claim(webhookId)) throw new DuplicateWebhookError(webhookId);

  return parsed as OutboundEvent;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function deliveryId(event: Record<string, unknown>): string | undefined {
  return typeof event.instance === "string" && Number.isSafeInteger(event.id) && (event.id as number) > 0
    ? `${event.instance}/${event.id}`
    : undefined;
}

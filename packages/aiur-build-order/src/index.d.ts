/** The contract id and version this package reads. */
export declare const BUILD_ORDER_CONTRACT: 'aiur.build_order';
export declare const BUILD_ORDER_VERSION: 1;
export declare const ELEMENT_NAME: 'aiur-build-order';

export type EdgeKind = 'depends_on' | 'serializes_with' | 'suggested_after' | 'contains' | 'gates';
export type EdgeState = 'cleared' | 'blocking' | 'terminal_unsatisfied' | 'unknown';
export type SourceStatus = 'known' | 'stale' | 'unknown';
export type GateStatus = 'open' | 'approved' | 'rejected' | 'unknown';

export declare const EDGE_TYPES: readonly EdgeKind[];
export declare const EDGE_LABELS: Readonly<Record<EdgeKind, string>>;
export declare const EDGE_NOTES: Readonly<Record<EdgeKind, string>>;
export declare const EDGE_STATES: readonly EdgeState[];
export declare const SOURCE_STATUSES: readonly SourceStatus[];
export declare const TICKET_STATUSES: readonly string[];
export declare const GATE_STATUSES: readonly GateStatus[];

export type BuildOrderErrorCode =
  | 'not_json'
  | 'not_an_object'
  | 'unsupported_contract'
  | 'unsupported_version'
  | 'invalid_field'
  | 'invalid_ticket'
  | 'invalid_edge'
  | 'missing_source'
  | 'fetch_failed';

export interface BuildOrderError {
  code: BuildOrderErrorCode;
  message: string;
  path: Array<string | number>;
}

/** One `progress` record, as the contract publishes it. */
export interface BuildOrderProgress {
  status: SourceStatus;
  total: number | null;
  done: number | null;
  open: number | null;
  failed: number | null;
  percent: number | null;
  by_status: Record<string, number> | null;
  observed_at: string | null;
  reason: string | null;
}

export interface BuildOrderSource {
  name: 'pack' | 'tracker' | 'progress';
  status: SourceStatus;
  observed_at: string | null;
  reason: string | null;
}

export interface BuildOrderEdge {
  kind: EdgeKind;
  from: string;
  to: string;
  state: EdgeState | null;
  source: 'pack' | 'tracker' | 'inferred' | 'unknown';
  fromKind: 'ticket' | 'gate';
  toKind: 'ticket' | 'gate';
}

export interface BuildOrderTicket {
  id: string;
  number: number | null;
  title: string;
  url: string | null;
  kind: 'executable' | 'audit' | 'gate' | 'umbrella' | 'capstone' | 'unknown';
  provenance: 'planned' | 'discovered' | 'unknown';
  epic: string | null;
  feature: string | null;
  lane: string | null;
  phase: number | null;
  wave: number | null;
  complexity: number | null;
  points: number | null;
  estimate_hours: number | null;
  status: string;
  progress_percent: number | null;
  started_at: string | null;
  ended_at: string | null;
  /** Every edge with this ticket at either end, attached by the parser. */
  edges: BuildOrderEdge[];
  /** True when `critical_path` lists this ticket. */
  critical: boolean;
}

export interface BuildOrderGate {
  key: string;
  title: string;
  owner: string | null;
  resolution_criteria: string | null;
  status: GateStatus;
}

export interface BuildOrderScope {
  key: string;
  title: string;
  label: string;
  url: string | null;
  icon: string | null;
  hue: number | null;
  epic: string | null;
  order: number | null;
  features: string[];
  progress: BuildOrderProgress;
}

export interface BuildOrderWave {
  index: number;
  label: string;
  tickets: string[];
  starts_at: string | null;
  ends_at: string | null;
}

export interface BuildOrderCriticalPath {
  status: 'known' | 'unknown';
  tickets: string[];
  hours: number | null;
  reason: string | null;
}

export interface BuildOrderRoot {
  id: string | null;
  title: string | null;
  number: number | null;
  url: string | null;
  epic: string | null;
  plan_version: number | null;
  researched_at_commit: string | null;
}

/** A parsed `build-order.v1` document plus the lookups a renderer needs. */
export interface BuildOrderDocument {
  contract: 'aiur.build_order';
  contract_version: 1;
  build_order_id: string;
  title: string;
  repository: string | null;
  root: BuildOrderRoot | null;
  generated_at: string;
  sources: Record<'pack' | 'tracker' | 'progress', BuildOrderSource>;
  progress: BuildOrderProgress;
  epics: BuildOrderScope[];
  features: BuildOrderScope[];
  lanes: BuildOrderScope[];
  tickets: BuildOrderTicket[];
  edges: BuildOrderEdge[];
  gates: BuildOrderGate[];
  waves: BuildOrderWave[];
  critical_path: BuildOrderCriticalPath;
  /** The worst published source status; `known` only when every source is known. */
  status: SourceStatus;
  statusReason: string | null;
  byId: Map<string, BuildOrderTicket>;
  gatesByKey: Map<string, BuildOrderGate>;
}

export type ParseResult =
  | { ok: true; document: BuildOrderDocument }
  | { ok: false; error: BuildOrderError };

/** Parse a JSON string, a parsed object or a fetch body into one document. */
export declare function parseBuildOrder(input: unknown): ParseResult;

/** Build a structured error in the same shape the parser returns. */
export declare function buildOrderError(
  code: BuildOrderErrorCode,
  message: string,
  path?: Array<string | number>,
): ParseResult;

/** The review page as static HTML. Throws an error carrying `code` and `path` when the input does not parse. */
export declare function renderReview(input: BuildOrderDocument | string | object): string;

/** The graph as static SVG. Throws an error carrying `code` and `path` when the input does not parse. */
export declare function renderGraph(input: BuildOrderDocument | string | object): string;

export declare class AiurBuildOrderElement extends HTMLElement {
  static readonly observedAttributes: string[];
  json: string | object | null;
  fetch: ((input: string, init?: object) => Promise<unknown>) | null;
  readonly view: 'review' | 'graph' | 'both';
  readonly document: BuildOrderDocument | null;
  readonly error: BuildOrderError | null;
  load(): Promise<void>;
  render(): void;
}

/** Define <aiur-build-order> once. Returns true when this call defined it. */
export declare function registerAiurBuildOrder(registry?: CustomElementRegistry): boolean;

export declare const STYLES: string;
export declare const STYLESHEET_NAME: 'aiur-build-order.css';

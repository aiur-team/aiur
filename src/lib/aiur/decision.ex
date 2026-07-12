defmodule Aiur.Decision do
  @moduledoc """
  Canonical, versioned Decision representation. `Aiur.DecisionValidation`
  normalizes an untrusted `decision.requested` payload into this struct;
  `Aiur.DecisionStore` is the only writer of accepted values.

  Schema version 1 fields:

    * `decision_id` — canonical identity, scoped by trusted ticket context
      (see `Aiur.DecisionValidation`). Stable across versions/replays.
    * `source_id` — the agent-proposed identity from the raw payload,
      preserved for correlation; never used as the canonical identity.
    * `version` — starts at 1; an accepted append-only enrichment
      increments it by exactly 1.
    * `ticket` — `%{identifier, title, url}`, injected from trusted
      runtime context, never from the raw agent payload.
    * `source` — `%{agent_id, session_id, event_id}`.
    * `kind` — free-form bounded category string (e.g. "architecture",
      "destructive_op", "credential", "product").
    * `authority` — `:human_required | :supervisor_allowed | :supervisor_preferred`.
    * `urgency` — `:low | :normal | :high | :critical`.
    * `blocking` — boolean.
    * `reversibility` — `:reversible | :irreversible | :partially_reversible`.
    * `question` — the exact question text.
    * `context` — `%{short_summary, long_context_markdown}`.
    * `options` — list of `%{id, label, description, benefits, drawbacks, risk}`.
    * `recommendation` — `%{option_id, reason}` or `nil`.
    * `consequence_of_delay` — bounded text or `nil`.
    * `artifacts` — list of `%{kind: :path | :url, value: String.t()}`.
    * `created_at` — canonical acceptance time, stamped by the store.
    * `source_created_at` — optional agent-reported time, provenance only;
      never controls audit order or notification age.
    * `legacy_attention` — optional trusted `%{slug, topic}` provenance for a
      Decision projected from the pre-OCC attention path.
    * `content_hash` — hash of the normalized payload (excludes
      `decision_id`/`version`/`created_at`), used for dedup/idempotency.
  """

  @type authority :: :human_required | :supervisor_allowed | :supervisor_preferred
  @type urgency :: :low | :normal | :high | :critical
  @type reversibility :: :reversible | :irreversible | :partially_reversible

  @type option :: %{
          id: String.t(),
          label: String.t(),
          description: String.t() | nil,
          benefits: String.t() | nil,
          drawbacks: String.t() | nil,
          risk: String.t() | nil
        }

  @type artifact :: %{kind: :path | :url, value: String.t()}
  @type legacy_attention :: %{slug: String.t(), topic: String.t()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          decision_id: String.t(),
          source_id: String.t() | nil,
          version: pos_integer(),
          ticket: %{identifier: String.t(), title: String.t() | nil, url: String.t() | nil},
          source: %{
            agent_id: String.t() | nil,
            session_id: String.t() | nil,
            event_id: String.t() | nil
          },
          kind: String.t() | nil,
          authority: authority(),
          urgency: urgency(),
          blocking: boolean(),
          reversibility: reversibility(),
          question: String.t(),
          context: %{short_summary: String.t() | nil, long_context_markdown: String.t() | nil},
          options: [option()],
          recommendation: %{option_id: String.t(), reason: String.t() | nil} | nil,
          consequence_of_delay: String.t() | nil,
          artifacts: [artifact()],
          created_at: DateTime.t(),
          source_created_at: DateTime.t() | nil,
          legacy_attention: legacy_attention() | nil,
          content_hash: String.t()
        }

  @schema_version 1

  @enforce_keys [
    :decision_id,
    :version,
    :ticket,
    :source,
    :authority,
    :urgency,
    :blocking,
    :reversibility,
    :question,
    :context,
    :options,
    :artifacts,
    :created_at,
    :content_hash
  ]
  defstruct @enforce_keys ++
              [
                schema_version: @schema_version,
                source_id: nil,
                kind: nil,
                recommendation: nil,
                consequence_of_delay: nil,
                source_created_at: nil,
                legacy_attention: nil
              ]

  @authorities [:human_required, :supervisor_allowed, :supervisor_preferred]
  @urgencies [:low, :normal, :high, :critical]
  @reversibilities [:reversible, :irreversible, :partially_reversible]

  @doc "Current schema version new Decisions are stamped with."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec authorities() :: [authority()]
  def authorities, do: @authorities

  @spec urgencies() :: [urgency()]
  def urgencies, do: @urgencies

  @spec reversibilities() :: [reversibility()]
  def reversibilities, do: @reversibilities
end

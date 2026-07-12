defmodule Aiur.Decision do
  @moduledoc """
  Canonical, versioned Decision representation. `Aiur.DecisionValidation`
  normalizes an untrusted `decision.requested` payload into this struct;
  `Aiur.DecisionStore` is the only writer of accepted values.

  Schema version 1 request fields and lifecycle projection fields:

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
    * `decision_status` — `:open | :decided | :acknowledged | :resolved`.
    * `delivery_status` — transport evidence, independent of decision state.
    * `answer` — the immutable original accepted `Aiur.DecisionAnswer`, or `nil`.
    * `active_action_id` — the original answer action or newest revision action.
    * `revisions` — ordered immutable `Aiur.DecisionRevision` corrections.
    * `revision_result` / `revision_outcomes` — semantic revision results,
      separate from transport and acknowledgement evidence.
    * `revision_follow_ups` — canonical blocking follow-up lifecycle by action.
    * `dispatch_attempts` — ordered correlated queue attempts for every action.
    * `acknowledgement` / `resolution` — current action lifecycle facts;
      `acknowledgements` / `resolutions` preserve them for every action.
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
  @type decision_status :: :open | :decided | :acknowledged | :resolved
  @type delivery_status :: :not_dispatched | :pending | :queued | :delivered | :consumed | :failed
  @type revision_result :: :recorded | :dispatched | :no_longer_applicable

  @type dispatch_attempt :: %{
          action_id: String.t(),
          attempt_id: String.t(),
          queue_item_id: pos_integer() | nil,
          run_id: String.t(),
          status: :queued | :delivered | :restored | :consumed | :failed,
          attempted_at: DateTime.t(),
          queued_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          restored_at: DateTime.t() | nil,
          consumed_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          failure_reason_class: String.t() | nil
        }

  @type revision_outcome :: %{
          result: revision_result(),
          reason_class: String.t() | nil,
          occurred_at: DateTime.t(),
          event_id: pos_integer() | String.t(),
          run_id: String.t()
        }

  @type revision_follow_up :: %{
          action_id: String.t(),
          slug: String.t(),
          question: String.t(),
          required_at: DateTime.t(),
          required_event_id: pos_integer() | String.t(),
          handled_at: DateTime.t() | nil,
          handled_event_id: pos_integer() | String.t() | nil,
          handled_by: Aiur.DecisionAnswer.actor() | nil,
          handled_detail: String.t() | nil
        }

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
          content_hash: String.t(),
          decision_status: decision_status(),
          delivery_status: delivery_status(),
          answer: Aiur.DecisionAnswer.t() | nil,
          active_action_id: String.t() | nil,
          revision_sequence: non_neg_integer(),
          revisions: [Aiur.DecisionRevision.t()],
          revision_result: revision_result() | nil,
          revision_outcomes: %{String.t() => revision_outcome()},
          revision_follow_ups: %{String.t() => revision_follow_up()},
          dispatch_attempts: [dispatch_attempt()],
          acknowledgement: map() | nil,
          resolution: map() | nil,
          acknowledgements: %{String.t() => map()},
          resolutions: %{String.t() => map()}
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
                legacy_attention: nil,
                decision_status: :open,
                delivery_status: :not_dispatched,
                answer: nil,
                active_action_id: nil,
                revision_sequence: 0,
                revisions: [],
                revision_result: nil,
                revision_outcomes: %{},
                revision_follow_ups: %{},
                dispatch_attempts: [],
                acknowledgement: nil,
                resolution: nil,
                acknowledgements: %{},
                resolutions: %{}
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

  @doc "Returns the immutable answer for the currently active action."
  @spec active_answer(t()) :: Aiur.DecisionAnswer.t() | nil
  def active_answer(%__MODULE__{revisions: []} = decision), do: decision.answer
  def active_answer(%__MODULE__{revisions: revisions}), do: revisions |> List.last() |> Map.fetch!(:answer)

  @doc "Finds the immutable answer associated with one original or revision action."
  @spec answer_for_action(t(), String.t()) :: Aiur.DecisionAnswer.t() | nil
  def answer_for_action(%__MODULE__{} = decision, action_id) when is_binary(action_id) do
    [decision.answer | Enum.map(decision.revisions, & &1.answer)]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&(&1.action_id == action_id))
  end

  @doc "Returns only dispatch attempts correlated to the active action."
  @spec active_dispatch_attempts(t()) :: [dispatch_attempt()]
  def active_dispatch_attempts(%__MODULE__{} = decision) do
    Enum.filter(decision.dispatch_attempts, &(&1.action_id == decision.active_action_id))
  end
end

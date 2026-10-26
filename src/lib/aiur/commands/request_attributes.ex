defmodule Aiur.Commands.RequestAttributes do
  @moduledoc false

  require Logger

  alias Aiur.DecisionStore.Persistence
  alias Aiur.Signal

  @keys [:requester, :origin, :native, :questions]

  @spec from_opts(keyword()) :: map()
  def from_opts(opts), do: opts |> Keyword.take(@keys) |> Map.new() |> Map.reject(fn {_key, value} -> is_nil(value) end)

  @spec append(map(), Aiur.Decision.t(), map(), term()) :: {map(), Aiur.Decision.t(), term()}
  def append(state, decision, attrs, request_event_id) when map_size(attrs) == 0, do: {state, decision, request_event_id}

  def append(state, decision, attrs, request_event_id) do
    case Persistence.build_and_append_event(:request_attributed, decision, attrs, decision.created_at, state) do
      {:ok, next_state, updated, event} ->
        {next_state, updated, event.event_id}

      {:error, reason} ->
        Logger.warning("aiur_decision_store phase=request_attribute_append_failed decision_id=#{decision.decision_id}")

        _ =
          Signal.agent_alert("system.decision.attributes.append_failed", "Command accepted without confirmed request attributes.",
            reason: "Command #{decision.decision_id}; inspect decision store health.",
            needs_attention: true
          )

        {Persistence.journal_failure_state(state, reason), decision, request_event_id}
    end
  end
end

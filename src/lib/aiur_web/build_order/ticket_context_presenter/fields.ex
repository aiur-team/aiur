defmodule AiurWeb.BuildOrder.TicketContextPresenter.Fields do
  @moduledoc false

  alias Aiur.Bounded
  alias Aiur.DisplaySanitizer
  alias Aiur.OpaqueIdentifier
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter.View

  @history_states [:available, :known_empty, :missing_source, :restart_unknown, :stale, :unavailable]
  @max_logs 100
  @max_title_bytes 512
  @max_description_bytes 4_000

  @spec max_logs() :: pos_integer()
  def max_logs, do: @max_logs
  @spec max_title_bytes() :: pos_integer()
  def max_title_bytes, do: @max_title_bytes
  @spec max_description_bytes() :: pos_integer()
  def max_description_bytes, do: @max_description_bytes

  @spec lifecycle_state(term()) :: :open | :closed | :unknown
  def lifecycle_state(state) when state in [:open, :closed], do: state
  def lifecycle_state(_state), do: :unknown
  @spec lifecycle_reason(term()) :: atom()
  def lifecycle_reason(reason) when reason in [:completed, :not_planned, :duplicate, :reopened, :none], do: reason
  def lifecycle_reason(_reason), do: :unknown

  @spec configured_identity(term()) :: TrackerIdentity.t() | nil
  def configured_identity(%TrackerIdentity{} = identity) do
    if safe_repository_identity?(identity) and TrackerIdentity.joinable?(identity), do: identity
  end

  def configured_identity(_identity), do: nil

  @spec same_identity?(term(), term()) :: boolean()
  def same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    case {TrackerIdentity.github_key(left), TrackerIdentity.github_key(right)} do
      {nil, _right} -> false
      {left, left} -> true
      _different -> false
    end
  end

  def same_identity?(_left, _right), do: false

  @spec repository_label(term()) :: String.t()
  def repository_label(%TrackerIdentity{owner: owner, repository: repository}), do: "#{owner}/#{repository}"
  def repository_label(_identity), do: "Configured repository"
  @spec identifier(term()) :: String.t() | nil
  def identifier(%TrackerIdentity{identifier: identifier}) when is_binary(identifier), do: identifier
  def identifier(_identity), do: nil

  @spec history_state(term()) :: atom()
  def history_state(state) when state in @history_states, do: state
  def history_state(_state), do: :unavailable
  @spec freshness(term()) :: :fresh | :stale | :unknown
  def freshness(value) when value in [:fresh, :stale, :unknown], do: value
  def freshness(_value), do: :unknown

  @spec source_health(term()) :: %{activity: atom(), history: atom()}
  def source_health(source_health) when is_map(source_health) do
    %{
      activity: map_value(source_health, :activity, @history_states, :unavailable),
      history: map_value(source_health, :history, @history_states, :unavailable)
    }
  end

  def source_health(_source_health), do: unavailable_source_health()
  @spec unavailable_source_health() :: %{activity: :unavailable, history: :unavailable}
  def unavailable_source_health, do: %{activity: :unavailable, history: :unavailable}
  @spec percent(term()) :: 0..100 | nil
  def percent(value) when is_integer(value) and value in 0..100, do: value
  def percent(_value), do: nil
  @spec positive_integer(term()) :: pos_integer() | nil
  def positive_integer(value) when is_integer(value) and value > 0, do: value
  def positive_integer(_value), do: nil

  @spec evidence_source(term()) :: map() | nil
  def evidence_source(%{kind: kind, name: name}) when kind in [:agent_event, :agent_alert, :legacy] and is_binary(name) do
    case OpaqueIdentifier.normalize(name) do
      nil -> nil
      safe_name -> %{kind: kind, name: safe_name}
    end
  end

  def evidence_source(_source), do: nil

  @spec provenance(term()) :: map()
  def provenance(provenance) when is_map(provenance) do
    Enum.reduce([:run_id, :attempt, :session_id, :source_event_id], %{}, fn key, result ->
      case map_value(provenance, key) do
        value when is_integer(value) and value >= 0 -> Map.put(result, key, value)
        value when is_binary(value) -> maybe_put_safe_opaque(result, key, value)
        _ -> result
      end
    end)
  end

  def provenance(_provenance), do: %{}

  @spec map_value(term(), atom(), [atom()] | nil, term()) :: term()
  def map_value(map, key, allowed \\ nil, fallback \\ nil)

  def map_value(map, key, allowed, fallback) when is_map(map) and is_list(allowed) do
    value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
    if value in allowed, do: value, else: fallback
  end

  def map_value(map, key, nil, _fallback) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  def map_value(_map, _key, _allowed, fallback), do: fallback

  @spec datetime(term()) :: DateTime.t() | nil
  def datetime(%DateTime{} = value), do: value
  def datetime(_value), do: nil

  @spec safe_title(term(), term()) :: String.t()
  def safe_title(value, identity) do
    case safe_text(value, @max_title_bytes) do
      {:ok, ""} -> fallback_title(identity)
      {:ok, title} -> title
      :error -> fallback_title(identity)
    end
  end

  @spec fallback_title(term()) :: String.t()
  def fallback_title(nil), do: "Ticket context unavailable"
  def fallback_title(identity), do: "Ticket #{identifier(identity) || "context"}"

  @spec safe_description(term()) :: String.t() | nil
  def safe_description(nil), do: nil

  def safe_description(value) do
    case safe_text(value, 64_000) do
      {:ok, ""} ->
        nil

      {:ok, description} when byte_size(description) > @max_description_bytes ->
        description |> binary_part(0, @max_description_bytes) |> String.replace_invalid("")

      {:ok, description} ->
        description

      :error ->
        nil
    end
  end

  @spec description_truncated?(term()) :: boolean()
  def description_truncated?(value) do
    case safe_text(value, 64_000) do
      {:ok, description} -> byte_size(description) > @max_description_bytes
      :error -> false
    end
  end

  @spec safe_text(term(), non_neg_integer()) :: {:ok, String.t()} | :error
  def safe_text(value, limit) when is_binary(value) do
    case DisplaySanitizer.sanitize(value, limit) do
      {:ok, value} -> {:ok, String.trim(value)}
      :error -> :error
    end
  end

  def safe_text(_value, _limit), do: :error

  @spec safe_repository_identity?(term()) :: boolean()
  def safe_repository_identity?(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier}) do
    with {:ok, _repository} <- Bounded.github_repository_components(owner, repository),
         {:ok, _identifier} <- Bounded.github_issue_identifier(identifier) do
      true
    else
      _ -> false
    end
  end

  @spec maybe_put_safe_opaque(map(), term(), term()) :: map()
  def maybe_put_safe_opaque(map, key, value) do
    case OpaqueIdentifier.normalize(value) do
      nil -> map
      safe -> Map.put(map, key, safe)
    end
  end

  @spec unavailable_view() :: View.t()
  def unavailable_view do
    %View{
      identity: nil,
      repository: "Configured repository",
      identifier: nil,
      title: "Ticket context unavailable",
      description: nil,
      lifecycle: %{state: :unknown, reason: :unknown},
      detail: %{state: :unavailable, observed_at: nil, last_success_at: nil, last_attempt_at: nil},
      history: %{
        state: :unavailable,
        freshness: :unknown,
        observed_at: nil,
        source_health: unavailable_source_health()
      },
      progress: %{status: :unknown, percent: nil, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}},
      latest_evidence: %{status: :unknown, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}},
      logs: %{entries: [], truncated?: false, observed_at: nil},
      capabilities: []
    }
  end
end

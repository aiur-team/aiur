defmodule AiurWeb.OperatorControlCenter.UnitsRow.Sources do
  @moduledoc false

  alias Aiur.{Issue, TrackerIdentity}
  alias AiurWeb.OperatorControlCenter.UnitsRow.Value

  @type source_set :: %{
          membership: map(),
          status: map(),
          activity: map(),
          decisions: map(),
          issue: map()
        }

  # Kept in step with `UnitsPresenter`, which reports the same window on the
  # catalog's own status. See `fleet_stale_after_seconds/0`.
  @fleet_stale_after_seconds 300

  @spec normalize(map()) :: source_set()
  def normalize(inputs) do
    %{
      membership: source(inputs, :membership),
      status: source(inputs, :status),
      activity: source(inputs, :activity),
      decisions: source(inputs, :decisions),
      issue: source(inputs, :issue_facts)
    }
  end

  @spec indexes(source_set()) :: map()
  def indexes(sources) do
    %{
      status: status_index(sources.status),
      activity: identity_index(entries(sources.activity)),
      decisions: identity_index(entries(sources.decisions)),
      issue: identity_index(entries(sources.issue))
    }
  end

  @spec entries(map() | [map()] | term()) :: [map()]
  def entries(%{} = source) do
    case Map.get(source, :members) || Map.get(source, :entries) || Map.get(source, :rows) do
      rows when is_list(rows) -> rows
      _rows -> Map.get(source, :items, [])
    end
  end

  def entries(rows) when is_list(rows), do: rows
  def entries(_source), do: []

  @spec matching_rows(TrackerIdentity.t(), map()) :: map()
  def matching_rows(identity, indexes) do
    identity_key = key(identity)
    Map.new(indexes, fn {source, rows} -> {source, Map.get(rows, identity_key)} end)
  end

  @spec identity(Issue.t() | map() | term()) :: TrackerIdentity.t() | nil
  def identity(%Issue{} = issue), do: Issue.tracker_identity(issue)
  def identity(%{} = value), do: Map.get(value, :identity) || Map.get(value, :tracker_identity)
  def identity(_value), do: nil

  @spec key(TrackerIdentity.t() | term()) :: String.t() | nil
  def key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  def key(_identity), do: nil

  @spec generation(source_set()) :: map()
  def generation(sources) do
    %{
      membership: Value.get(sources.membership, :generation),
      status: Value.get(sources.status, :generation),
      activity: Value.get(sources.activity, :generation),
      decisions: Value.get(sources.decisions, :generation),
      issue: Value.get(sources.issue, :generation)
    }
  end

  @spec health(source_set()) :: map()
  def health(sources) do
    %{
      membership: source_health(sources.membership),
      status: source_health(sources.status),
      activity: source_health(sources.activity),
      decisions: source_health(sources.decisions),
      issue: source_health(sources.issue)
    }
  end

  @spec freshness(source_set()) :: map()
  def freshness(sources) do
    %{
      membership: Value.get(sources.membership, :freshness) || :unknown,
      status: Value.get(sources.status, :freshness) || :unknown,
      activity: Value.get(sources.activity, :freshness) || :unknown,
      decisions: Value.get(sources.decisions, :freshness) || :unknown,
      issue: Value.get(sources.issue, :freshness) || :unknown
    }
  end

  @spec truncated?(source_set()) :: boolean()
  def truncated?(sources), do: Value.get(sources.membership, :truncated?) == true

  @doc """
  Returns how old a retained fleet view may be and still act as the row floor.

  The Stream Deck projects a `:stale` orchestrator snapshot exactly as it
  projects a current one, so admitting rows only from a `:fresh` fleet view
  makes the two surfaces disagree about how many agents exist: the deck keeps
  showing the retained fleet while the Units catalog silently drops every
  status-sourced row. Both surfaces therefore share one tolerance, and only a
  genuinely old fleet view stops being a valid floor.
  """
  @spec fleet_stale_after_seconds() :: pos_integer()
  def fleet_stale_after_seconds, do: @fleet_stale_after_seconds

  @spec current_status?(source_set()) :: boolean()
  def current_status?(sources) do
    source_health(sources.status) in [:healthy, :available] and
      usable_freshness?(sources.status)
  end

  # A `:stale` fleet view still carries every agent the orchestrator last
  # published, so it stays a usable floor until it ages out. `:unknown` and
  # `:unavailable` have no age to judge and never qualify.
  defp usable_freshness?(source) do
    case {freshness_status(source), freshness_age_seconds(source)} do
      {status, _age_seconds} when status in [:fresh, :current] -> true
      {:stale, age_seconds} when is_integer(age_seconds) and age_seconds < @fleet_stale_after_seconds -> true
      _freshness -> false
    end
  end

  @spec descriptor(map() | term(), map() | term()) :: map()
  def descriptor(source, entry) do
    %{
      available?: not is_nil(entry),
      health: source_health(source),
      freshness: Value.get(source, :freshness) || Value.get(source, :status) || :unknown,
      generation: Value.get(source, :generation)
    }
  end

  defp source(inputs, key) do
    Map.get(inputs, key) || Map.get(inputs, Atom.to_string(key)) || %{}
  end

  defp status_index(snapshot) do
    [:idle, :retrying, :running]
    |> Enum.reduce(%{}, &index_status_bucket(snapshot, &1, &2))
  end

  defp index_status_bucket(snapshot, bucket, index) do
    snapshot
    |> Value.get(bucket, [])
    |> List.wrap()
    |> Enum.reduce(index, &put_status_entry(&1, bucket, &2))
  end

  defp put_status_entry(entry, bucket, index) do
    put_identity(index, entry, Map.put(entry, :bucket, bucket))
  end

  defp identity_index(rows) do
    Enum.reduce(rows, %{}, &put_identity(&2, &1, &1))
  end

  defp put_identity(index, source_entry, entry) do
    case identity(source_entry) do
      %TrackerIdentity{} = identity -> maybe_put_identity(index, identity, entry)
      _identity -> index
    end
  end

  defp maybe_put_identity(index, identity, entry) do
    if TrackerIdentity.joinable?(identity), do: Map.put(index, key(identity), entry), else: index
  end

  defp source_health(source) do
    case Value.get(source, :health) do
      {:degraded, _reason} -> :degraded
      {:unavailable, _reason} -> :unavailable
      %{status: status} -> status
      status when status in [:healthy, :available, :degraded, :unavailable, :unknown] -> status
      _status -> :unknown
    end
  end

  defp freshness_status(source) do
    case Value.get(source, :freshness) do
      %{status: status} -> status
      status when is_atom(status) -> status
      _freshness -> :unknown
    end
  end

  defp freshness_age_seconds(source) do
    case Value.get(source, :freshness) do
      %{age_seconds: age_seconds} when is_integer(age_seconds) and age_seconds >= 0 -> age_seconds
      _freshness -> nil
    end
  end
end

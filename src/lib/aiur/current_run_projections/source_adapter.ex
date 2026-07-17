defmodule Aiur.CurrentRunProjections.SourceAdapter do
  @moduledoc false

  alias Aiur.CurrentRunProjection.Value
  alias Aiur.{RecentMerge, TrackerIdentity}

  @keys [:run, :membership, :status, :status_facts, :activity, :merges, :configured_repository]
  @run_fields [:id, :started_at, :observed_at, :elapsed_ms, :valid?]
  @member_fields [:identity, :lifecycle, :terminal?, :first_observed_at, :last_observed_at]

  @status_fields [
    :tracker_identity,
    :identity,
    :state,
    :tracker_state,
    :work_state,
    :waiting_reason,
    :pause_reason,
    :tracker_paused,
    :runtime_seconds,
    :stale_for_seconds,
    :started_at,
    :open_decision_count
  ]

  @merge_fields [
    :id,
    :repository,
    :number,
    :title,
    :summary,
    :url,
    :head_ref,
    :head_sha,
    :merge_commit_sha,
    :merged_at,
    :observation_source,
    :backfilled?,
    :live_observed?,
    :observed_run_id,
    :first_observed_at,
    :last_observed_at
  ]

  @spec keys() :: [atom()]
  def keys, do: @keys

  @spec read(atom(), (-> term())) :: {:ok, term()} | {:error, atom()}
  def read(key, fun) when key in @keys and is_function(fun, 0) do
    case fun.() do
      :timeout -> {:error, :timeout}
      :unavailable -> {:error, :unavailable}
      value -> sanitize(key, value)
    end
  rescue
    _error -> {:error, :exception}
  catch
    _kind, _reason -> {:error, :exit}
  end

  defp sanitize(:run, run) when is_map(run) do
    sanitized = run |> take(@run_fields) |> Map.put(:valid?, Value.get(run, :valid?, true) != false)
    {:ok, sanitized}
  end

  defp sanitize(:membership, membership) when is_map(membership) do
    members =
      membership
      |> Value.get(:members, [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&sanitize_member/1)

    {:ok,
     %{
       run_id: Value.get(membership, :run_id),
       generation: Value.get(membership, :generation),
       health: Value.get(membership, :health),
       freshness: Value.get(membership, :freshness),
       truncated?: Value.get(membership, :truncated?, false) == true,
       members: members
     }}
  end

  defp sanitize(:status, status) when is_map(status) do
    {:ok,
     %{
       generation: Value.get(status, :generation),
       health: :available,
       freshness: :fresh,
       running: sanitize_status_bucket(status, :running),
       retrying: sanitize_status_bucket(status, :retrying),
       idle: sanitize_status_bucket(status, :idle)
     }}
  end

  defp sanitize(:status_facts, facts) when is_list(facts) do
    {:ok, facts |> Enum.filter(&is_map/1) |> Enum.map(&sanitize_status_fact/1)}
  end

  defp sanitize(:activity, activity) when is_map(activity) do
    raw_entries = activity |> Value.get(:entries, []) |> List.wrap()
    entries = raw_entries |> Enum.filter(&is_map/1) |> Enum.map(&sanitize_activity/1)
    invalid? = length(entries) != length(raw_entries)
    stale? = Enum.any?(entries, &(get_in(&1, [:progress, :freshness]) == :stale))

    {:ok,
     %{
       generation: Value.get(activity, :generation),
       entries: entries,
       health: if(invalid?, do: :degraded, else: :available),
       freshness: activity_freshness(invalid?, stale?)
     }}
  end

  defp sanitize(:merges, snapshot) when is_map(snapshot) do
    merges = snapshot |> Value.get(:merges, []) |> List.wrap() |> Enum.map(&sanitize_merge/1)

    {:ok,
     %{
       generation: Value.get(snapshot, :generation),
       health: Value.get(snapshot, :health),
       reconciliation: sanitize_reconciliation(Value.get(snapshot, :reconciliation)),
       merges: merges
     }}
  end

  defp sanitize(:configured_repository, {:ok, {owner, repository}} = value)
       when is_binary(owner) and is_binary(repository),
       do: {:ok, value}

  defp sanitize(:configured_repository, {:error, _reason} = error), do: {:ok, error}
  defp sanitize(_key, _value), do: {:error, :invalid_shape}

  defp sanitize_member(member) do
    member
    |> take(@member_fields)
    |> Map.update(:identity, nil, &sanitize_identity/1)
  end

  defp sanitize_status_bucket(status, key) do
    status
    |> Value.get(key, [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn row ->
      row
      |> take(@status_fields)
      |> Map.update(:tracker_identity, nil, &sanitize_identity/1)
      |> Map.update(:identity, nil, &sanitize_identity/1)
    end)
  end

  defp sanitize_status_fact(fact) do
    %{
      identity: sanitize_identity(Value.get(fact, :identity, nil) || Value.get(fact, :tracker_identity, nil)),
      state: Value.get(fact, :tracker_state, nil) || Value.get(fact, :state, nil),
      complexity: Value.get(fact, :complexity)
    }
  end

  defp sanitize_activity(entry) do
    %{
      identity: sanitize_identity(Value.get(entry, :identity, nil) || Value.get(entry, :tracker_identity, nil)),
      progress: sanitize_progress(Value.get(entry, :progress))
    }
  end

  defp sanitize_progress(progress) when is_map(progress) do
    take(progress, [:status, :percent, :source, :freshness])
  end

  defp sanitize_progress(_progress), do: %{status: :unknown}

  defp sanitize_merge(%RecentMerge{} = merge) do
    struct(RecentMerge, Map.take(Map.from_struct(merge), @merge_fields))
  end

  defp sanitize_merge(_merge), do: :invalid_merge

  defp sanitize_reconciliation(value) when is_map(value) do
    take(value, [:status, :partial?, :pages_fetched])
  end

  defp sanitize_reconciliation(_value), do: %{}
  defp sanitize_identity(%TrackerIdentity{} = identity), do: identity
  defp sanitize_identity(_identity), do: nil
  defp activity_freshness(true, _stale?), do: :partial
  defp activity_freshness(false, true), do: :stale
  defp activity_freshness(false, false), do: :fresh

  defp take(map, keys) do
    Map.new(keys, fn key -> {key, Value.get(map, key, nil)} end)
  end
end

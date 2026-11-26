defmodule AiurWeb.Api.UsageProgress do
  @moduledoc """
  Versioned, read-only progress and phase read for one ticket (#5694).

  Composes three existing read models without changing how any of them is
  produced:

    * `Aiur.TicketActivity` — the live projection of the ticket's current
      workflow phase and latest progress reading;
    * `Aiur.ProgressRetention` — the durable last progress reading, used when
      the live projection has none (restart, pruned entry, slow projection);
    * the ticket's shared-event-bus history (`Aiur.AgentEventFeed`) — the
      ordered progress, check-in and phase-transition events behind those values.

  Every field says whether it is known. A ticket nothing has been observed for
  answers `status: "unknown"` fields and an empty event list; it is never
  reported as idle or at 0%. `sources.activity` separates "nothing observed"
  from "could not read": a projection that failed is `unavailable`, not empty.

  Percentages go through `Aiur.BuildOrder.ProgressRenderer.json/1`, the shared
  progress presentation boundary, so this surface never formats a raw reading.
  """

  alias Aiur.BuildOrder.ProgressRenderer
  alias Aiur.{JSONSafe, ProgressRetention, TicketActivity, TrackerIdentity}
  alias AiurWeb.Api.UsageProgress.History

  @contract "aiur.ticket_progress"
  @contract_version 1
  # Same queueing budget as the status report's read of this projection.
  @activity_timeout_ms 500
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @doc """
  Builds the wire payload for `identifier`.

  Options (test seams; production uses the defaults):
    * `:activity_fun` — 0-arity, returns `TicketActivity.snapshots/1` output
    * `:retention_fun` — 0-arity, returns `ProgressRetention.all/0` output
    * `:history_fun` — `AgentEventFeed.bus_events/2`-shaped reader
    * `:limit` — newest events to return (1..50, default 20)
    * `:now` — the `generated_at` timestamp
  """
  @spec payload(String.t(), keyword()) :: {:ok, map()} | {:error, :invalid_identifier}
  def payload(identifier, opts \\ []) do
    if is_binary(identifier) and Regex.match?(@identifier, identifier) do
      {:ok, build(identifier, opts)}
    else
      {:error, :invalid_identifier}
    end
  end

  defp build(identifier, opts) do
    {activity_source, entry} = live_entry(identifier, Keyword.get(opts, :activity_fun, &live_snapshots/0))
    retained = retained_entry(identifier, entry, Keyword.get(opts, :retention_fun, &ProgressRetention.all/0))
    identity = entry_identity(entry) || entry_identity(retained)

    JSONSafe.normalize(%{
      contract: @contract,
      contract_version: @contract_version,
      issue_identifier: identifier,
      repository: repository(identity),
      phase: phase(entry),
      progress: progress(entry, retained),
      events: History.read(identifier, opts),
      sources: %{activity: activity_source},
      generated_at: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    })
  end

  defp live_snapshots, do: TicketActivity.snapshots(timeout: @activity_timeout_ms)

  # An unstarted or too-slow projection is "could not read", reported as such;
  # it must not collapse into "this ticket has no phase".
  defp live_entry(identifier, activity_fun) do
    case activity_fun.() do
      %{entries: entries} when is_list(entries) -> {:available, latest(entries, identifier, & &1[:observed_at])}
      _other -> {:unavailable, nil}
    end
  catch
    :exit, _reason -> {:unavailable, nil}
  end

  defp retained_entry(identifier, entry, retention_fun) do
    case retention_fun.() do
      retained when is_map(retained) ->
        retained
        |> Map.values()
        |> Enum.filter(&same_ticket?(&1, entry))
        |> latest(identifier, &get_in(&1, [:progress, :observed_at]))

      _other ->
        nil
    end
  end

  # Once a live entry has chosen the repository, a retained reading from
  # another repository's same-numbered ticket must not fill its progress.
  defp same_ticket?(_retained, nil), do: true

  defp same_ticket?(retained, entry),
    do: TrackerIdentity.github_key(entry_identity(retained)) == TrackerIdentity.github_key(entry_identity(entry))

  # Several configured repositories can share a display number; the newest
  # observation wins and `repository` names which one answered.
  defp latest(entries, identifier, observed_at) do
    entries
    |> Enum.filter(&match?(%{identity: %TrackerIdentity{identifier: ^identifier}}, &1))
    |> Enum.max_by(&sort_key(observed_at.(&1)), fn -> nil end)
  end

  defp sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_key(_unknown), do: -1

  defp entry_identity(%{identity: %TrackerIdentity{} = identity}), do: identity
  defp entry_identity(_entry), do: nil

  defp repository(%TrackerIdentity{owner: owner, repository: repo}) when is_binary(owner) and is_binary(repo),
    do: "#{owner}/#{repo}"

  defp repository(_identity), do: nil

  # A phase is a state with explicit start/end transitions, not a decaying
  # measurement, so it carries no freshness. `value: nil` with a known status
  # means the last phase ended and no other has started.
  defp phase(%{stage: %{status: :known} = stage}),
    do: %{status: :known, value: stage[:value], observed_at: stage[:observed_at]}

  defp phase(_entry), do: %{status: :unknown}

  defp progress(%{progress: %{status: :known, percent: percent} = live}, _retained) when is_number(percent),
    do: reading(live, live[:freshness])

  # The retained reading is real but at least as old as the live staleness
  # window, so it is reported stale — never replaced with 0.
  defp progress(_entry, %{progress: %{percent: percent} = retained}) when is_number(percent),
    do: reading(retained, :stale)

  defp progress(_entry, _retained), do: %{status: :unknown}

  defp reading(progress, freshness) do
    case rendered_percent(progress.percent) do
      nil -> %{status: :unknown}
      percent -> known_reading(progress, percent, freshness)
    end
  end

  # The reading becomes the RootSummary progress contract and is rendered by
  # ProgressRenderer; an out-of-range reading stays unknown, never clamped.
  defp rendered_percent(value) when value >= 0 and value <= 100,
    do: %{progress: round(value), progress_resolution: :resolved} |> ProgressRenderer.json() |> Map.fetch!("progress")

  defp rendered_percent(_value), do: nil

  defp known_reading(progress, percent, freshness) do
    %{
      status: :known,
      percent: percent,
      source: progress[:source],
      freshness: freshness,
      occurred_at: progress[:occurred_at],
      observed_at: progress[:observed_at]
    }
  end
end

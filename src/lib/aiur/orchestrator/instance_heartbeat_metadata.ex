defmodule Aiur.Orchestrator.InstanceHeartbeatMetadata do
  @moduledoc false

  alias Aiur.Gateway.Identity
  alias Aiur.Instance.LeaseStore
  alias Aiur.Instance.LeaseStore.TicketKey
  alias Aiur.Orchestrator.InstanceHeartbeatMetadata.{ProjectSignals, SizeBudget}

  @spec metadata(keyword()) :: map()
  def metadata(opts \\ []) do
    statuses = Keyword.get(opts, :statuses_fun, &statuses/0).()
    ownership = Keyword.get(opts, :ownership_metadata_fun, &Aiur.Instance.heartbeat_metadata/0).()
    ownership_data = ownership_data(ownership)
    gateway = Keyword.get(opts, :gateway_identity_fun, &Identity.current/0).()

    data =
      Map.merge(ownership_data, %{
        "gateway_id" => gateway.gateway_id,
        "gateway_label" => gateway.gateway_label,
        "gateway_identity" => gateway.gateway_identity
      })

    held = contained(Keyword.get(opts, :held_tickets_fun, &held_tickets/0))

    # A field this gateway cannot read is omitted, never zero-filled: readers render a missing key as unknown.
    workload =
      drop_nil(%{
        "host_kind" => Keyword.get(opts, :host_kind_fun, &host_kind/0).(),
        "public_url" => Keyword.get(opts, :public_url_fun, &public_url/0).(),
        "agent_count" => count_agents(statuses),
        "agent_capacity" => contained(Keyword.get(opts, :capacity_fun, &agent_capacity/0)),
        "held_tickets" => held,
        "executor_present" => contained(Keyword.get(opts, :executor_fun, fn -> nil end)),
        "projects" => projects(statuses, held, signals(opts)),
        "agents" => agent_rows(statuses)
      })

    %{"version" => 1, "data" => SizeBudget.fit(Map.merge(data, workload), Keyword.get(opts, :max_bytes, SizeBudget.max_bytes()))}
  end

  # A slow or dead dependency must not crash the Heartbeat process: its field is simply omitted.
  defp contained(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp drop_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp signals(opts) do
    %{
      next_queue: contained(Keyword.get(opts, :next_queue_fun, &ProjectSignals.next_queue/0)),
      pending_decisions: contained(Keyword.get(opts, :pending_decisions_fun, &ProjectSignals.pending_decisions/0))
    }
  end

  defp projects(statuses, held, signals) when is_list(statuses) do
    active = Enum.filter(statuses, &active_agent?/1)
    running = Enum.frequencies_by(active, &repo_of/1)

    repos = Enum.uniq(Enum.map(active, &repo_of/1) ++ if(is_list(held), do: Enum.map(held, &repo_of/1), else: []))

    repos
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn repo ->
      drop_nil(%{
        "repo" => repo,
        "running" => Map.get(running, repo, 0),
        "agents" => Map.get(running, repo, 0),
        "next_queue" => queue_entry(signals.next_queue, repo),
        "pending_decisions" => signals.pending_decisions && Map.get(signals.pending_decisions, repo, 0),
        "owned_tickets" => if(is_list(held), do: Enum.count(held, &(repo_of(&1) == repo)))
      })
    end)
  end

  defp projects(_, _, _), do: nil

  # nil source or a repo the queue does not serve: omitted. A served repo with nothing ready is `%{"number" => nil}`.
  defp queue_entry(%{} = by_repo, repo) when is_map_key(by_repo, repo), do: %{"number" => by_repo[repo]}
  defp queue_entry(_, _), do: nil

  # Project id = downcased owner/name from the lease store's own ticket key, so running rows (bare-number
  # identifier + tracker_identity) and held keys (owner/repo#N) group under one key.
  defp repo_of(row_or_key) do
    case TicketKey.ticket_key(row_or_key) do
      {:ok, key} -> key |> String.split("#") |> hd()
      _ -> nil
    end
  end

  defp ownership_data(%{"version" => 1, "data" => data}) when is_map(data), do: data
  defp ownership_data(_), do: %{}

  defp statuses do
    case Aiur.Orchestrator.status(Aiur.Project.whereis(Aiur.Orchestrator), 1_000) do
      statuses when is_list(statuses) -> statuses
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp count_agents(statuses) when is_list(statuses), do: Enum.count(statuses, &active_agent?/1)
  defp count_agents(_), do: nil

  defp agent_rows(statuses) when is_list(statuses) do
    statuses
    |> Enum.filter(&active_agent?/1)
    |> Enum.map(fn row ->
      %{"identifier" => row.identifier, "title" => row.title, "state" => to_string(row.state)}
    end)
  end

  defp agent_rows(_), do: nil

  defp active_agent?(row), do: row.state in [:running, :paused]

  defp agent_capacity do
    case Aiur.Orchestrator.max_concurrent_agents() do
      %{effective: effective} when is_integer(effective) -> effective
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp held_tickets do
    case LeaseStore.owned_tickets() do
      {:ok, tickets} -> tickets
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp host_kind do
    if File.exists?("/run/.containerenv") or File.exists?("/.dockerenv"), do: "container", else: "home"
  end

  defp public_url do
    case Aiur.Config.settings() do
      {:ok, %{server: %{public_url: url}}} -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end
end

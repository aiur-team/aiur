defmodule Aiur.Orchestrator.InstanceHeartbeatMetadata do
  @moduledoc false

  alias Aiur.Instance.LeaseStore

  @spec metadata(keyword()) :: map()
  def metadata(opts \\ []) do
    statuses = Keyword.get(opts, :statuses_fun, &statuses/0).()

    %{
      "version" => 1,
      "data" => %{
        "host_kind" => Keyword.get(opts, :host_kind_fun, &host_kind/0).(),
        "public_url" => Keyword.get(opts, :public_url_fun, &public_url/0).(),
        "agent_count" => count_agents(statuses),
        "agent_capacity" => Keyword.get(opts, :capacity_fun, &agent_capacity/0).(),
        "held_tickets" => Keyword.get(opts, :held_tickets_fun, &held_tickets/0).(),
        "agents" => agent_rows(statuses),
        "leader" => nil
      }
    }
  end

  defp statuses do
    case Aiur.Orchestrator.status() do
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
  end

  defp held_tickets do
    case LeaseStore.owned_tickets() do
      {:ok, tickets} -> tickets
      _ -> nil
    end
  rescue
    _ -> nil
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

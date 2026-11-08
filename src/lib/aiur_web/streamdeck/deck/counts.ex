defmodule AiurWeb.Streamdeck.Deck.Counts do
  @moduledoc "Stream Deck counts from the same index window as the Build page."
  alias AiurWeb.{Build.Index, EndpointConfig}
  alias AiurWeb.Streamdeck.Deck.Tickets

  @doc "Fleet categories over the exact filed, deduplicated Ticket view population."
  @spec categories(map()) :: map()
  def categories(counts) do
    by_state = counts.by_state
    known = ~w(active native_question command error retrying ci_wait usage_limited parked paused)
    unknown = counts.agents - Enum.sum(Map.values(Map.take(by_state, known)))

    %{
      active: Map.get(by_state, "active", 0) + unknown,
      unknown: unknown,
      command: Map.get(by_state, "command", 0) + Map.get(by_state, "native_question", 0),
      error: Map.get(by_state, "error", 0) + Map.get(by_state, "retrying", 0),
      ci_wait: Map.get(by_state, "ci_wait", 0),
      usage_limited: Map.get(by_state, "usage_limited", 0),
      paused: Map.get(by_state, "parked", 0) + Map.get(by_state, "paused", 0),
      queued: counts.queued,
      live: counts.agents
    }
  end

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    result = Keyword.get_lazy(opts, :window, fn -> window(opts) end)
    project(result)
  rescue
    _error -> unavailable()
  catch
    :exit, _reason -> unavailable()
  end

  @doc "The shared Build window used by Deck sections, read once per projection."
  @spec window(keyword()) :: {:ok, map()} | {:error, term()}
  def window(opts \\ []) do
    read = EndpointConfig.get(:streamdeck_build_window_fun) || (&index_window/3)
    read.(Keyword.get(opts, :index, Index), "Etc/UTC", 5_000)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp index_window(server, zone, timeout) do
    with :ok <- Index.subscribe(server), do: Index.window(server, zone, timeout)
  end

  defp project({:ok, window}) do
    source = window |> field(:sources) |> field(:agents)

    case field(source, :state) do
      state when state in ["ok", "stale"] -> counts(window, source, state)
      _ -> unavailable()
    end
  end

  defp project(_error), do: unavailable()

  defp counts(window, source, status) do
    sections = field(window, :sections)
    {plan, now} = sections |> Tickets.keys() |> Enum.split_with(&(&1.state == :queued))
    by_state = Enum.frequencies_by(now, &(&1.state || "unknown"))

    %{
      status: status,
      observed_at: field(source, :observed_at),
      agents: length(now),
      live: Map.get(by_state, "active", 0),
      queued: length(plan),
      not_queued: length(field(sections, :nq)),
      by_state: by_state
    }
  end

  defp unavailable, do: %{status: "unavailable", observed_at: nil, agents: nil, live: nil, queued: nil, not_queued: nil, by_state: nil}
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end

defmodule AiurWeb.Streamdeck.Deck.Counts do
  @moduledoc "Stream Deck counts from the same index window as the Build page."
  alias AiurWeb.{Build.Index, EndpointConfig}

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    read = EndpointConfig.get(:streamdeck_build_window_fun) || (&window/3)
    result = Keyword.get_lazy(opts, :window, fn -> read.(Keyword.get(opts, :index, Index), "Etc/UTC", 5_000) end)
    project(result)
  rescue
    _error -> unavailable()
  catch
    :exit, _reason -> unavailable()
  end

  defp window(server, zone, timeout) do
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
    now = field(sections, :now)
    by_state = Enum.frequencies_by(now, &(field(field(&1, :agent), :state) || "unknown"))

    %{
      status: status,
      observed_at: field(source, :observed_at),
      agents: length(now),
      live: Map.get(by_state, "active", 0),
      queued: length(field(sections, :plan)),
      not_queued: length(field(sections, :nq)),
      by_state: by_state
    }
  end

  defp unavailable, do: %{status: "unavailable", observed_at: nil, agents: nil, live: nil, queued: nil, not_queued: nil, by_state: nil}
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end

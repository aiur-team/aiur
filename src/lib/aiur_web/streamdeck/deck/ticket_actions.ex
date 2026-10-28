defmodule AiurWeb.Streamdeck.Deck.TicketActions do
  @moduledoc "Configured ticket links and queue affordances for both deck surfaces."
  alias AiurWeb.Build.Read
  alias AiurWeb.{Endpoint, EndpointConfig}

  @spec links(String.t(), map() | nil, map() | nil) :: map()
  def links(id, row, unit) do
    pr = if row, do: row[:pr]

    url =
      case {pr, unit} do
        {%{num: num}, %{identity: %{kind: :github, owner: owner, repository: repo}}}
        when is_integer(num) and num > 0 and is_binary(owner) and is_binary(repo) ->
          "https://github.com/#{URI.encode_www_form(owner)}/#{URI.encode_www_form(repo)}/pull/#{num}"

        _ ->
          nil
      end

    %{modal: String.trim_trailing(Endpoint.url(), "/") <> "/build?ticket=" <> URI.encode_www_form(id), pr: url}
  end

  @spec availability(String.t(), map() | nil) :: map()
  def availability(id, control) do
    show = EndpointConfig.get(:streamdeck_build_queue_fun) || (&Aiur.BuildQueue.show/0)

    queue =
      case Read.safe_read(fn -> {:ok, show.()} end) do
        {:ok, value} -> value
        _ -> %{status: :unavailable}
      end

    writable = EndpointConfig.get(:dashboard_writable) == true
    {up, down} = queue_edges(queue, id)

    %{
      pause: if(control && control.state == :enabled, do: "enabled", else: "disabled"),
      priority_up: enabled(writable and up),
      priority_down: enabled(writable and down),
      mic: enabled(writable)
    }
  end

  defp queue_edges(%{snapshot: %{carried_age_ms: _}}, _id), do: {false, false}

  defp queue_edges(%{status: :running, queues: queues}, id) do
    Enum.find_value(queues, {false, false}, &list_edges(&1, id))
  end

  defp queue_edges(_, _id), do: {false, false}

  defp list_edges(%{kind: :list, items: items}, id) do
    case Enum.find(items, &(to_string(&1.number) == id)) do
      nil -> nil
      item -> {item.position > 0, item.position < length(items) - 1}
    end
  end

  defp list_edges(_, _id), do: nil
  defp enabled(true), do: "enabled"
  defp enabled(false), do: "disabled"
end

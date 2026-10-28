defmodule AiurWeb.Streamdeck.Deck.TicketPage do
  @moduledoc "Bounded focused-ticket reads over the desktop Build source."
  alias AiurWeb.Build.{DataSource, Payload, Read, TicketControl, TicketStatus}
  alias AiurWeb.EndpointConfig

  @spec subscribe() :: :ok
  def subscribe do
    # Activate the shared index even when there is no open desktop Build page.
    DataSource.call(source(), :subscribe, [[financial: :locked]])
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec read(String.t(), keyword()) :: map()
  def read(id, opts \\ []) do
    source = Keyword.get(opts, :build_source, source())
    row = read_row(source, :ticket, id, opts)
    unit = read_row(source, :unit_row, id, opts)
    control = TicketControl.encode(unit, nil, EndpointConfig.get(:dashboard_writable) == true).control
    agent = if row && row[:agent], do: Map.merge(row.agent, %{pct: row[:pct], start: row[:start]})

    %{
      v: 1,
      kind: "ticket",
      id: id,
      title: row && row[:title],
      sec: row && row[:sec],
      status: TicketStatus.encode(row),
      agent: agent,
      pr: row && row[:pr],
      control: control,
      qpos: row && row[:qpos],
      observed_at: Keyword.get(opts, :now, System.system_time(:millisecond))
    }
    |> Payload.scrub()
  end

  @spec push_focused(Phoenix.Socket.t()) :: :ok
  def push_focused(%{assigns: %{focused_agent: id}} = socket) when is_binary(id), do: Phoenix.Channel.push(socket, "ticket", read(id))
  def push_focused(_socket), do: :ok

  defp read_row(source, function, id, opts) do
    case Read.safe_read(fn -> DataSource.call(source, function, [id, opts]) end) do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp source, do: EndpointConfig.get(:streamdeck_build_source, DataSource.source())
end

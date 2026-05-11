defmodule SymphonyElixir.TUI.App do
  @moduledoc false

  use ExRatatui.App

  alias ExRatatui.Event.Key
  alias SymphonyElixir.Config
  alias SymphonyElixir.TUI.{SnapshotSource, State}
  alias SymphonyElixir.TUI.Widgets.StatusScreen

  @refresh :refresh

  @impl true
  def mount(opts) do
    snapshot_source = Keyword.get(opts, :snapshot_source, &SnapshotSource.snapshot/0)
    refresh_ms = Keyword.get(opts, :refresh_ms, Config.observability_refresh_ms())

    state =
      State.new(
        snapshot_source: snapshot_source,
        refresh_ms: refresh_ms
      )

    schedule_refresh(refresh_ms)
    {:ok, state}
  end

  @impl true
  def render(%State{} = state, frame), do: StatusScreen.render(state, frame)

  @impl true
  def handle_event(%Key{code: code, kind: kind}, state) when kind in [nil, "press", "repeat"] do
    case key_action(code) do
      :select_next -> {:noreply, State.select_next(state)}
      :select_previous -> {:noreply, State.select_previous(state)}
      :quit -> {:stop, state}
      :ignore -> {:noreply, state, render?: false}
    end
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

  @impl true
  def handle_info(@refresh, %State{} = state) do
    schedule_refresh(state.refresh_ms)
    {:noreply, State.refresh(state)}
  end

  def handle_info(_message, state), do: {:noreply, state, render?: false}

  defp key_action(code) when code in ["j", "down"], do: :select_next
  defp key_action(code) when code in ["k", "up"], do: :select_previous
  defp key_action("q"), do: :quit
  defp key_action(_code), do: :ignore

  defp schedule_refresh(refresh_ms) when is_integer(refresh_ms) and refresh_ms > 0 do
    Process.send_after(self(), @refresh, refresh_ms)
  end
end

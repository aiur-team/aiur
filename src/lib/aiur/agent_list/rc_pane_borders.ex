defmodule Aiur.AgentList.RcPaneBorders do
  @moduledoc """
  Reconciles remote-control URLs into tmux pane borders.
  """

  alias Aiur.PaneManager

  @spec reconcile(map()) :: map()
  def reconcile(state) do
    case safe_list_open_panes(state.pane_manager) do
      {:ok, open_panes} ->
        {changes, applied} = changes(open_panes, state.summaries, state.rc_pane_borders)
        Enum.each(changes, fn {pane_id, text} -> Aiur.Tmux.set_pane_border(state.tmux, pane_id, text) end)
        %{state | rc_pane_borders: applied}

      :unavailable ->
        state
    end
  end

  @spec changes(map(), [map()], map()) :: {[{String.t(), String.t() | nil}], map()}
  def changes(open_panes, summaries, applied) do
    urls = Map.new(summaries, fn summary -> {to_string(Map.get(summary, :identifier)), border_text(summary)} end)
    desired = Map.new(open_panes, fn {identifier, pane_id} -> {pane_id, Map.get(urls, to_string(identifier))} end)

    changes =
      for {pane_id, text} <- desired, Map.get(applied, pane_id) != text, do: {pane_id, text}

    next_applied = desired |> Enum.reject(fn {_pane_id, text} -> is_nil(text) end) |> Map.new()
    {changes, next_applied}
  end

  defp safe_list_open_panes(pane_manager) do
    {:ok, PaneManager.list_open_panes(pane_manager)}
  catch
    :exit, _ -> :unavailable
  end

  defp border_text(%{remote_control: %{status: :on, session_url: url}}) when is_binary(url),
    do: " 📱 " <> String.replace(url, "#", "##") <> " "

  defp border_text(_summary), do: nil
end

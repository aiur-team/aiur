defmodule Aiur.AgentList.Activation do
  @moduledoc """
  Performs selected-agent pane activation without blocking AgentList.
  """

  require Logger

  alias Aiur.AgentList.Summaries
  alias Aiur.{Orchestrator, PaneManager}

  @spec default_command_template() :: String.t()
  def default_command_template, do: "__aiur_opencode__"

  @spec activate_selected(map(), :new_pane | :swap_in_last_used) :: :ok
  def activate_selected(state, mode) do
    case Enum.at(state.summaries, state.selection_index) do
      %{identifier: identifier} = summary -> activate_if_available(state, identifier, summary, mode)
      _ -> :ok
    end
  end

  @spec attach_selected(map()) :: :ok
  def attach_selected(state) do
    case Enum.at(state.summaries, state.selection_index) do
      %{identifier: identifier} = summary ->
        Logger.info("[user-action] attach_selected identifier=#{identifier} source=agent_list")
        start_attach(state, identifier, summary)

      _ ->
        :ok
    end
  end

  defp activate_if_available(state, identifier, summary, mode) do
    cond do
      Summaries.deactivated?(summary) ->
        Logger.info("[user-action] reactivate_on_enter identifier=#{identifier} source=agent_list")
        start_reactivate(state.orchestrator, identifier)
        start_open(state, identifier, summary, mode)

      not warm_identifier?(state, identifier) ->
        Logger.info("[user-action] open_blocked identifier=#{identifier} source=agent_list reason=not_warm")

      mode == :new_pane and not has_parallel_headroom?(state, identifier) ->
        Logger.info("[user-action] open_blocked identifier=#{identifier} source=agent_list reason=no_headroom")

      true ->
        start_open(state, identifier, summary, mode)
    end

    :ok
  end

  defp start_reactivate(orchestrator, identifier) do
    Task.start(fn -> log_reactivate_result(orchestrator, identifier) end)
  end

  defp log_reactivate_result(orchestrator, identifier) do
    case safe_call(fn -> Orchestrator.resume_agent(orchestrator, identifier) end) do
      {:ok, _} -> :ok
      other -> Logger.debug("reactivate_on_enter resume_agent reply=#{inspect(other)}")
    end
  end

  defp start_open(state, identifier, summary, mode) do
    Logger.info("[user-action] open_conversation identifier=#{identifier} mode=#{mode} source=agent_list")
    Aiur.Perf.event(:user_pressed_enter, identifier: identifier, source: :agent_list, mode: mode)
    command = "#{state.command_template} #{identifier}"
    title = Map.get(summary, :title)
    pane_manager = state.pane_manager
    Task.start(fn -> open(pane_manager, identifier, command, title, mode) end)
  end

  defp start_attach(state, identifier, summary) do
    command = "#{state.command_template} #{identifier}"
    title = Map.get(summary, :title)
    pane_manager = state.pane_manager
    Task.start(fn -> attach_then_open(pane_manager, identifier, command, title) end)
  end

  defp open(pane_manager, identifier, command, title, :new_pane),
    do: PaneManager.open_conversation(pane_manager, identifier, command, title: title)

  defp open(pane_manager, identifier, command, title, :swap_in_last_used),
    do: attach_then_open(pane_manager, identifier, command, title)

  defp attach_then_open(pane_manager, identifier, command, title) do
    case PaneManager.attach_conversation(pane_manager, identifier, command, title: title) do
      {:ok, _pane_id} ->
        :ok

      {:error, :no_focused_pane} ->
        PaneManager.open_conversation(pane_manager, identifier, command,
          title: title,
          timeout: 65_000
        )

      {:error, _reason} ->
        :ok
    end
  end

  defp has_parallel_headroom?(state, identifier) do
    if MapSet.member?(Map.get(state, :opened_panes, MapSet.new()), to_string(identifier)) do
      true
    else
      match?(%{attach_count: count} when count >= 1, Map.get(state.attach_state, to_string(identifier)))
    end
  end

  defp warm_identifier?(state, identifier),
    do: match?(%{attach_count: count} when count > 0, Map.get(state.attach_state, identifier))

  defp safe_call(function) do
    function.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
    _, _ -> nil
  end
end

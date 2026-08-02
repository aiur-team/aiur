defmodule Aiur.AgentList.Activation do
  @moduledoc """
  Performs selected-agent pane activation without blocking AgentList.

  Every PaneManager open or attach runs inside `Task.start`: attaching carries
  a 65 s timeout and an open-fallback chain, so running it inline would park
  the App process. Capture pane_manager, command, and title before spawning.
  """

  require Logger

  alias Aiur.AgentList.Summaries
  alias Aiur.{Orchestrator, PaneManager}

  @spec default_command_template() :: String.t()
  def default_command_template, do: "__aiur_opencode__"

  @spec activate_selected(map(), :new_pane | :swap_in_last_used) :: :ok
  def activate_selected(state, mode) do
    case Enum.at(state.summaries, state.selection_index) do
      %{identifier: identifier} = summary -> activate_selected_agent_if_warm(state, identifier, summary, mode)
      _ -> :ok
    end
  end

  @spec attach_selected(map()) :: :ok
  def attach_selected(state) do
    case Enum.at(state.summaries, state.selection_index) do
      %{identifier: identifier} = summary ->
        if completed?(state, summary) do
          log_completed_block(identifier)
        else
          attach_selected_agent(state, identifier, summary)
        end

      _ ->
        :ok
    end
  end

  defp attach_selected_agent(state, identifier, summary) do
    Logger.info("[user-action] attach_selected identifier=#{identifier} source=agent_list")
    command = "#{state.command_template} #{identifier}"
    title = Map.get(summary, :title)
    pane_manager = state.pane_manager

    # `attach_conversation` has a 65 s timeout but would still park App.
    Task.start(fn -> attempt_attach_then_open(pane_manager, identifier, command, title) end)
  end

  defp activate_selected_agent_if_warm(state, identifier, summary, mode) do
    cond do
      completed?(state, summary) ->
        log_completed_block(identifier)

      Summaries.deactivated?(summary) ->
        # A deactivated row has no warm pane; reactivate and open asynchronously.
        Logger.info("[user-action] reactivate_on_enter identifier=#{identifier} source=agent_list")
        reactivate_and_open(state, identifier, summary, mode)

      not warm_identifier?(state, identifier) ->
        Logger.info("[user-action] open_blocked identifier=#{identifier} source=agent_list reason=not_warm")

      mode == :new_pane and not has_parallel_headroom?(state, identifier) ->
        Logger.info("[user-action] open_blocked identifier=#{identifier} source=agent_list reason=no_headroom")

      true ->
        open_selected_agent(state, identifier, summary, mode)
    end

    :ok
  end

  defp reactivate_and_open(state, identifier, summary, mode) do
    Task.start(fn -> log_reactivate_result(state, identifier) end)
    open_selected_agent(state, identifier, summary, mode)
  end

  defp log_reactivate_result(state, identifier) do
    case safe_call(fn -> Orchestrator.resume_agent(state.orchestrator, identifier) end) do
      {:ok, _} -> :ok
      other -> Logger.debug("reactivate_on_enter resume_agent reply=#{inspect(other)}")
    end
  end

  defp open_selected_agent(state, identifier, summary, mode) do
    Logger.info("[user-action] open_conversation identifier=#{identifier} mode=#{mode} source=agent_list")
    Aiur.Perf.event(:user_pressed_enter, identifier: identifier, source: :agent_list, mode: mode)
    command = "#{state.command_template} #{identifier}"
    title = Map.get(summary, :title)
    pane_manager = state.pane_manager
    Task.start(fn -> do_open(pane_manager, identifier, command, title, mode) end)
  end

  defp do_open(pane_manager, identifier, command, title, :new_pane),
    do: PaneManager.open_conversation(pane_manager, identifier, command, title: title)

  defp do_open(pane_manager, identifier, command, title, :swap_in_last_used),
    do: attempt_attach_then_open(pane_manager, identifier, command, title)

  defp attempt_attach_then_open(pane_manager, identifier, command, title) do
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

  defp completed?(state, summary) do
    Summaries.completed?(summary) or
      match?([{100, _timestamp} | _], get_in(state, [:progress_by_id, to_string(summary.identifier)]))
  end

  defp log_completed_block(identifier) do
    Logger.info("[user-action] open_blocked identifier=#{identifier} source=agent_list reason=completed")
  end

  defp safe_call(function) do
    function.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
    _, _ -> nil
  end
end

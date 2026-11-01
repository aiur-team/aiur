defmodule VoiceConverse.Session.Briefing do
  @moduledoc false

  alias VoiceConverse.{Briefing, Ports, TranscriptStore}
  alias VoiceConverse.Session.Runtime

  def refresh(state, session, caller) do
    ref = make_ref()
    config = state.config
    target = state.target

    Task.start(fn ->
      result = Ports.call_port(config.briefing_source, :brief, [target], :brief)
      send(session, {:briefing_refresh, ref, result})
    end)

    {:noreply, %{state | briefing_refreshes: Map.put(state.briefing_refreshes, ref, caller)}}
  end

  def complete_refresh(state, ref, result) do
    case Map.pop(state.briefing_refreshes, ref) do
      {nil, _refreshes} ->
        {:noreply, state}

      {caller, refreshes} ->
        state = %{state | briefing_refreshes: refreshes}

        case result do
          {:ok, %Briefing{} = briefing} ->
            case apply_refresh(state, briefing) do
              {:reply, reply, state} ->
                GenServer.reply(caller, reply)
                {:noreply, state}

              other ->
                other
            end

          _ ->
            GenServer.reply(caller, {:error, :unavailable})
            {:noreply, state}
        end
    end
  end

  defp apply_refresh(state, briefing) do
    changes =
      if match?(%Briefing{}, state.briefing),
        do: Briefing.diff(state.briefing, briefing),
        else: []

    text =
      changes
      |> Enum.join("\n")
      |> limit(state.config.limits.briefing_token_budget)
      |> redact(state)

    if text == "" do
      {:reply, :ok, %{state | briefing: briefing}}
    else
      observed_at = DateTime.to_iso8601(state.clock.())

      record = %{
        type: "context",
        source: "briefing",
        ref: target_ref(state),
        observed_at: observed_at,
        text: text,
        refresh?: true
      }

      case TranscriptStore.append(state.store, record) do
        :ok ->
          {:reply, :ok, Runtime.briefing_context(%{state | briefing: briefing}, text)}

        {:error, _reason} ->
          {:reply, {:error, :unavailable}, state}
      end
    end
  end

  defp target_ref(state),
    do:
      state.draft_target
      |> Map.get(:id, Map.get(state.draft_target, "id", "target"))
      |> to_string()

  defp redact(text, state), do: state.config.redactor.(text)

  defp limit(text, budget) do
    max_bytes = budget * 4
    if byte_size(text) <= max_bytes, do: text, else: binary_part(text, 0, max_bytes)
  end
end

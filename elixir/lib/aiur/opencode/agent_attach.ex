defmodule Aiur.Opencode.AgentAttach do
  @moduledoc """
  Per-identifier attach worker. Drives one agent's pane from "absent" to
  "hidden-ready" in `Aiur.Opencode.PersistentPane`'s state machine.

  Pure function module — not a GenServer. `attach/2` runs the full
  sequence inline and returns `{:ok, %PersistentPane{}}` or `{:error,
  reason}`. The `AttachQueue` serializes attaches and decides whether to
  promote the resulting pane to visible (vs leaving it `:hidden`) after
  this returns.

  Sequence (numbered to match the plan's state diagram):

    1. `SessionWriterRegistry.ensure/2` → creates the opencode session
       with the agent's real title, registers a `PersistentPane` value,
       spawns the SessionWriter. The writer's `handle_continue(:boot, …)`
       runs `replay_history/1` synchronously.
    2. `SessionWriter.await_replay/2` blocks until the writer has fully
       committed history rows.
    3. `Tmux.split_pane/5` spawns `opencode attach <session>` as a new
       pane inside the hidden window (targeting `HiddenWindow.keep_alive_pane`).
    4. `ApiClient.select_session/2` tells the (already-attached) TUI to
       load the agent's session.
    5. `post_message` sends a synthetic `__aiur_stream__:<msg_id>` marker
       through the bridge — opencode reacts to it as a user turn, which
       forces the TUI to re-fetch the assistant rows we just wrote.
    6. Update registry: status → `:hidden`, pane_id → new pane.

  Logs each phase as `opencode_agent_attach phase=<name> identifier=<id> elapsed_ms=<N>`
  so manual CLI verification can grep for transitions.
  """

  require Logger

  alias Aiur.Boot
  alias Aiur.Opencode.{
    ApiClient,
    HiddenWindow,
    PersistentPane,
    Protocol,
    SessionWriter,
    SessionWriterRegistry
  }

  alias Aiur.Tmux

  @hidden_split_percent 50

  @doc """
  Run the full attach sequence for `identifier` against the warm
  opencode server at `base_url`. Returns `{:ok, %PersistentPane{}}` once
  the pane lives in the hidden window with history replayed and the
  TUI selected to the agent's session.
  """
  @spec attach(String.t(), String.t()) ::
          {:ok, PersistentPane.t()} | {:error, term()}
  def attach(identifier, base_url)
      when is_binary(identifier) and is_binary(base_url) do
    started_at = System.monotonic_time(:millisecond)
    log_phase(identifier, "start", started_at)

    with {:ok, %{session_id: session_id, writer_pid: writer_pid}} <-
           SessionWriterRegistry.ensure(identifier, base_url),
         _ <- log_phase(identifier, "session_created", started_at, session_id: session_id),
         :ok <- SessionWriter.await_replay(writer_pid, 10_000),
         _ <- log_phase(identifier, "replay_complete", started_at, session_id: session_id),
         {:ok, target_pane} <- target_pane_for_hidden_window(),
         attach_cmd = Protocol.attach_command(base_url, session_id),
         {:ok, pane_id} <-
           Tmux.split_pane(target_pane, :horizontal, @hidden_split_percent, attach_cmd),
         _ <-
           log_phase(identifier, "tmux_spawned", started_at,
             session_id: session_id,
             pane_id: pane_id
           ),
         {:ok, _pane} <-
           SessionWriterRegistry.update_pane(identifier, fn pane ->
             pane
             |> PersistentPane.with_pane_id(pane_id)
             |> PersistentPane.with_status(:hidden)
           end),
         :ok <- ApiClient.select_session(base_url, session_id),
         _ <- log_phase(identifier, "tui_selected", started_at, session_id: session_id),
         :ok <- nudge_tui(base_url, session_id) do
      {:ok, final_pane} = SessionWriterRegistry.get_pane(identifier)
      log_phase(identifier, "ready", started_at, session_id: session_id, pane_id: pane_id)
      {:ok, final_pane}
    else
      {:error, reason} = err ->
        Logger.warning(
          "opencode_agent_attach phase=failed elapsed_ms=#{Boot.elapsed_ms()} attach_ms=#{System.monotonic_time(:millisecond) - started_at} identifier=#{identifier} reason=#{inspect(reason)}"
        )

        err

      other ->
        Logger.warning(
          "opencode_agent_attach phase=failed elapsed_ms=#{Boot.elapsed_ms()} attach_ms=#{System.monotonic_time(:millisecond) - started_at} identifier=#{identifier} reason=#{inspect(other)}"
        )

        {:error, other}
    end
  end

  defp target_pane_for_hidden_window do
    case HiddenWindow.status() do
      :ready ->
        # We need the keep-alive pane id to split against. Reading the
        # GenServer state isn't ideal, but HiddenWindow only exposes
        # `status/0` publicly today — extend the API rather than poking
        # internals. For now, read the keep_alive_pane_id off the
        # GenServer state via :sys.get_state (test-friendly fallback).
        try do
          state = :sys.get_state(HiddenWindow, 1_000)
          {:ok, state.keep_alive_pane_id}
        catch
          _, reason -> {:error, {:hidden_window_state_unavailable, reason}}
        end

      :waiting ->
        {:error, :hidden_window_not_ready}

      :failed ->
        {:error, :hidden_window_failed}

      :disabled ->
        {:error, :hidden_window_disabled}
    end
  end

  defp nudge_tui(base_url, session_id) do
    marker = "__aiur_stream__:nudge:#{System.unique_integer([:positive])}"
    payload = %{parts: [Protocol.text_part_data(marker, synthetic: true)]}

    case ApiClient.post_message(base_url, session_id, payload) do
      {:ok, _} -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp log_phase(identifier, phase, started_at, extra \\ []) do
    attach_ms = System.monotonic_time(:millisecond) - started_at
    extras = Enum.map_join(extra, " ", fn {k, v} -> "#{k}=#{v}" end)

    Logger.info(
      "opencode_agent_attach phase=#{phase} elapsed_ms=#{Boot.elapsed_ms()} attach_ms=#{attach_ms} identifier=#{identifier} #{extras}"
      |> String.trim_trailing()
    )
  end
end

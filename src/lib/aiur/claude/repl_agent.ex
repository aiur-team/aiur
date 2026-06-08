defmodule Aiur.Claude.ReplAgent do
  @moduledoc """
  Persistent interactive-REPL Claude backend implementing the CodingAgent
  behaviour.

  Where `Aiur.Claude.CodingAgent` spawns `claude --print` one-shot per turn
  over JSON-RPC stdio, this driver keeps ONE long-lived interactive `claude`
  process alive in a hidden tmux pane and drives it with `send-keys`. Because
  the process persists, it can be launched with `--remote-control` so the same
  agent is also drivable from the Claude app (phone / claude.ai/code) — both
  surfaces share one transcript. Turn output is read by tailing that transcript
  jsonl (see `Aiur.Claude.TranscriptTailer`), not by scraping the pane.

  This module owns the session lifecycle: spawn the pane, wait for the REPL to
  become ready, optionally attach Remote Control, resolve the transcript path
  (cwd + newest mtime — the interactive `/remote-control` path writes no
  `bridge-pointer.json`), and tear the pane + process down cleanly so no
  `claude` process is orphaned.
  """

  @behaviour Aiur.CodingAgent

  require Logger

  alias Aiur.Claude.Config
  alias Aiur.Claude.RemoteControl
  alias Aiur.Tmux

  @ready_prompt "❯"
  @ready_poll_ms 200
  @ready_timeout_ms 15_000

  @type session :: %{
          backend: String.t(),
          pane_id: String.t(),
          os_pid: integer() | nil,
          workspace: Path.t(),
          transcript_path: Path.t() | nil,
          model: String.t() | nil,
          remote_control: boolean(),
          rc_name: String.t() | nil,
          tmux: GenServer.server()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    tmux = Keyword.get(opts, :tmux, Tmux)
    expanded = Path.expand(workspace)
    model = Keyword.get(opts, :model) || Config.model()
    rc? = Keyword.get(opts, :remote_control, false)
    rc_name = Keyword.get(opts, :rc_name) || "aiur-repl-#{System.unique_integer([:positive])}"
    window_name = Keyword.get(opts, :window_name) || rc_name

    command = build_command(expanded, model, rc?, rc_name)

    Aiur.Perf.event(:repl_agent_spawn, workspace: expanded, remote_control: rc?)

    case Tmux.new_hidden_window(tmux, window_name, command) do
      {:ok, pane_id} ->
        finish_start(tmux, pane_id, expanded, model, rc?, rc_name, opts)

      {:error, _reason} = err ->
        err
    end
  end

  defp finish_start(tmux, pane_id, expanded, model, rc?, rc_name, opts) do
    timeout = Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)

    case await_ready(tmux, pane_id, timeout) do
      :ok ->
        os_pid =
          case Tmux.pane_pid(tmux, pane_id) do
            {:ok, pid} -> pid
            _ -> nil
          end

        transcript_path =
          RemoteControl.resolve_transcript_path(
            workspace: expanded,
            projects_dir: Keyword.get(opts, :projects_dir)
          )

        Aiur.Perf.event(:repl_agent_ready,
          workspace: expanded,
          pane_id: pane_id,
          os_pid: os_pid,
          remote_control: rc?
        )

        {:ok,
         %{
           backend: "claude-repl",
           pane_id: pane_id,
           os_pid: os_pid,
           workspace: expanded,
           transcript_path: transcript_path,
           model: model,
           remote_control: rc?,
           rc_name: rc_name,
           tmux: tmux
         }}

      {:error, :repl_not_ready} = err ->
        # Readiness failed but the pane exists — kill it so nothing leaks.
        Tmux.kill_pane(tmux, pane_id)
        err
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{tmux: tmux, pane_id: pane_id} = session) do
    Tmux.kill_pane(tmux, pane_id)
    RemoteControl.graceful_kill(Map.get(session, :os_pid))

    Aiur.Perf.event(:repl_agent_teardown,
      workspace: Map.get(session, :workspace),
      pane_id: pane_id,
      os_pid: Map.get(session, :os_pid)
    )

    :ok
  end

  def stop_session(_session), do: :ok

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    # Usage / rate-limit normalization is identical to the headless backend.
    Aiur.Claude.CodingAgent.normalize_event(event)
  end

  @doc false
  # Implemented in U3 (run_turn over the REPL). Defined here to satisfy the
  # CodingAgent behaviour while the lifecycle (U1) lands first.
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:error, :not_implemented}
  def run_turn(_session, _prompt, _issue, _opts \\ []), do: {:error, :not_implemented}

  @doc false
  # Implemented in U4 (instant mid-turn operator delivery).
  @spec send_operator_message(session(), Aiur.CodingAgent.operator_payload()) ::
          {:error, :not_implemented}
  def send_operator_message(_session, _payload), do: {:error, :not_implemented}

  # ------------------------------------------------------------------ internals

  # `exec` replaces the wrapping shell so the pane's top process IS `claude`,
  # which makes `pane_pid` the process graceful_kill must terminate.
  defp build_command(workspace, model, rc?, rc_name) do
    flags =
      ["claude"]
      |> append_if(rc?, ["--remote-control", shell_escape(rc_name)])
      |> Kernel.++(["--permission-mode", shell_escape(Config.permission_mode())])
      |> append_if(is_binary(model), ["--model", shell_escape(model || "")])
      |> Enum.join(" ")

    "cd #{shell_escape(workspace)} && exec #{flags}"
  end

  defp append_if(list, true, extra), do: list ++ extra
  defp append_if(list, false, _extra), do: list
  defp append_if(list, nil, _extra), do: list

  defp await_ready(tmux, pane_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ready(tmux, pane_id, deadline)
  end

  defp do_await_ready(tmux, pane_id, deadline) do
    case Tmux.capture_pane(tmux, pane_id) do
      {:ok, lines} ->
        if Enum.any?(lines, &String.contains?(&1, @ready_prompt)) do
          :ok
        else
          retry_ready(tmux, pane_id, deadline)
        end

      {:error, _} ->
        retry_ready(tmux, pane_id, deadline)
    end
  end

  defp retry_ready(tmux, pane_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :repl_not_ready}
    else
      Process.sleep(@ready_poll_ms)
      do_await_ready(tmux, pane_id, deadline)
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end

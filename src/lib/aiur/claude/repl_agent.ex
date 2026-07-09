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

  alias Aiur.Claude.Repl.Command
  alias Aiur.Claude.Repl.HookTurn
  alias Aiur.Claude.Repl.Launcher
  alias Aiur.Claude.Repl.OperatorInject
  alias Aiur.Claude.Repl.Reaper
  alias Aiur.Claude.Repl.TranscriptTurn
  alias Aiur.Tmux

  @type session :: %{
          backend: String.t(),
          pane_id: String.t(),
          os_pid: integer() | nil,
          workspace: Path.t(),
          transcript_path: Path.t() | nil,
          projects_dir: Path.t() | nil,
          started_at: integer(),
          model: String.t() | nil,
          remote_control: boolean(),
          rc_name: String.t() | nil,
          session_url: String.t() | nil,
          resumed: boolean(),
          thread_id: String.t() | nil,
          identifier: String.t() | nil,
          tmux: GenServer.server()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace),
    do: Launcher.start_session(workspace, opts)

  @spec stop_session(session()) :: :ok
  defdelegate stop_session(session), to: Reaper

  @doc """
  Kill orphaned REPL panes left by a crashed or hard-killed aiur instance.

  REPL window names embed the owning BEAM's os pid; this kills only panes
  whose owner pid is no longer alive, so a side-by-side aiur instance's live
  panes are never touched. Called at boot alongside
  `Aiur.Claude.RemoteControl.reap_orphaned_servers/0`.
  """
  @spec reap_orphaned_panes(GenServer.server()) :: :ok
  defdelegate reap_orphaned_panes(tmux \\ Tmux), to: Reaper

  @doc """
  Kill this instance's own REPL panes on graceful shutdown.

  The supervisor brutally kills the runner tasks, skipping their `after
  stop_session` cleanup, so without this sweep a graceful shutdown leaks
  every live REPL pane + `claude` process. Matches only windows owned by
  this BEAM's os pid so a side-by-side aiur instance is never touched.
  """
  @spec sweep_own_panes(GenServer.server()) :: :ok
  defdelegate sweep_own_panes(tmux \\ Tmux), to: Reaper

  @doc """
  Inject an operator message straight into the live REPL pane.

  This is the whole of mid-turn delivery: sanitize the text, type it with
  `send_keys_literal`, then submit with one `Enter`. The agent's native
  input queue does the rest — it folds the message in at the next natural
  boundary without aborting in-flight work, so there is no bespoke
  interrupt-then-send path here (cutting the agent off is a separate,
  explicit parity action, not this one).

  Operator text is typed verbatim into a PTY, so it is sanitized first:
  every control byte (newlines that would submit early, `Esc`/C0/C1
  sequences that would trip the REPL's own keybindings) is collapsed to a
  space. The single trailing `Enter` is the only submit.
  """
  @spec send_operator_message(session(), Aiur.CodingAgent.operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  defdelegate send_operator_message(session, payload), to: OperatorInject

  @doc """
  Interrupt the REPL's current turn by sending `Ctrl+C` to its pane.

  This is the explicit operator-interrupt path: unlike
  `send_operator_message/2`, which lets Claude's native queue fold a
  message in at the next boundary without aborting in-flight work, this
  cuts the active turn at Claude's next safe point so a queued message is
  drained immediately.
  """
  @spec interrupt(map()) :: :ok | {:error, term()}
  defdelegate interrupt(session), to: OperatorInject

  @doc false
  @spec resume_session_id(keyword(), Path.t()) :: String.t() | nil
  defdelegate resume_session_id(opts, workspace), to: Command

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    # Usage / rate-limit normalization is identical to the headless backend.
    Aiur.Claude.CodingAgent.normalize_event(event)
  end

  @doc """
  Drive one turn over the persistent REPL.

  Sends `prompt` to the live pane (`paste_text` + `Enter`), tails the
  shared transcript for this turn's output (forwarding each extracted
  `transcript_event` to `on_message`), and blocks until the agent's terminal
  `stop_reason` lands or a backstop fires:

    * `{:ok, %{result, session_id, thread_id, turn_id}}` on completion
    * `{:error, :empty_prompt}` if the prompt is blank (no keys sent)
    * `{:error, :no_transcript}` if a cold-start turn's jsonl never appeared
    * `{:error, :turn_timeout}` if no completion arrives within the backstop;
      the session stays usable for the next turn
    * `{:error, :repl_gone}` if the pane dies mid-turn

  On a warm turn the tailer opens `from: :end` so it captures only this
  turn's newly-appended records. On a cold-start turn (no jsonl yet) the
  prompt is sent first so claude creates the file, then the tailer opens
  `from: :start` to pick up records written before it attached. Either way
  the tailer never replays prior history as input to the agent.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:paused, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ [])

  def run_turn(_session, prompt, _issue, _opts) when not is_binary(prompt),
    do: {:error, :empty_prompt}

  def run_turn(%{} = session, prompt, _issue, opts) do
    if String.trim(prompt) == "" do
      {:error, :empty_prompt}
    else
      drive_turn(session, prompt, opts)
    end
  end

  defp drive_turn(session, prompt, opts) do
    if is_binary(Map.get(session, :identifier)) do
      HookTurn.run(session, prompt, opts)
    else
      TranscriptTurn.run(session, prompt, opts)
    end
  end
end

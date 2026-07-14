defmodule Aiur.CodingAgent.Backend do
  @moduledoc """
  The behaviour every coding-agent backend adapter implements.

  A backend is exactly two things:

    1. one adapter module implementing these callbacks, and
    2. one entry in `Aiur.CodingAgent.backends/0` — the registry, the
       single source of backend identity.

  Adding a backend must require nothing else: no new `case` clause in
  dispatch code, no edits outside the new module and its registry
  entry. Cross-backend variance is either a callback here or a
  declared capability in the registry entry (`t:capabilities/0`).
  Unknown backends fail loud in the registry accessors, never here.

  ## Session contract

  A session is the adapter-owned map returned by `c:start_session/2`
  and threaded through every later callback. `Aiur.AgentRunner`
  additionally tags it with `:backend` (the resolved registry key)
  after start, and reads these adapter-set keys:

    * `:thread_id` — the backend-native session/thread id when known
      (`nil` until the first turn for adapters that learn it late).
    * `:resumed` — `true` only when `c:start_session/2` successfully
      rejoined the thread named by `opts[:resume_thread_id]`.

  ## Resume contract

  Resume is carried by `c:start_session/2`, not a separate callback:
  a backend whose registry entry declares `resumable: true` receives
  `opts[:resume_thread_id]` and must attempt to rejoin that thread,
  setting `resumed: true` on success and degrading silently to a
  clean start (`resumed: false`) on any failure — a resume miss must
  never strand an issue. Non-resumable backends never receive the
  option.

  ## Interrupt policy

  In-turn interruption is in-band: the runner sends
  `{:pause_agent, request_id}` and
  `{:agent_queue_updated, identifier, item_id, deliver_now?}` to the
  process executing `c:run_turn/4`. The registry flags
  `can_interrupt` / `safe_checkpoints` / `immediate_delivery` declare
  how the runner schedules delivery around those messages. The
  optional `c:interrupt/1` callback is the out-of-band variant for
  backends whose live process is cut externally (the persistent REPL:
  Ctrl+C into the pane).
  """

  alias Aiur.CodingAgent

  @typedoc "The adapter-owned session map. See \"Session contract\"."
  @type session :: map()

  @typedoc """
  One registry entry in `Aiur.CodingAgent.backends/0`. Required keys
  exist on every backend; optional keys are declared capabilities:

    * `:immediate_delivery` — Executor messages pass straight through
      to the live process instead of holding at a checkpoint.
    * `:remote_transport` — the backend an RC-promoted session
      actually runs on (remote control physically runs on the
      persistent-REPL transport).
    * `:fallback_backend` — the backend a failed spawn degrades to,
      once, so a transport failure never strands an issue.
  """
  @type capabilities :: %{
          required(:adapter) => module(),
          required(:transcript) => module(),
          required(:family) => String.t(),
          required(:can_interrupt) => boolean(),
          required(:safe_checkpoints) => [atom()],
          optional(:control_application_confirmation) => :confirmed | :request_only | :unsupported,
          required(:remote_control) => boolean(),
          required(:resumable) => boolean(),
          required(:models) => [String.t()],
          required(:efforts) => [String.t()],
          optional(:immediate_delivery) => boolean(),
          optional(:remote_transport) => CodingAgent.backend(),
          optional(:fallback_backend) => CodingAgent.backend()
        }

  @doc "Start a session in the workspace. See \"Resume contract\"."
  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}

  @doc """
  Run one prompt turn. `{:paused, map()}` covers quota exhaustion and
  Executor pause; the runner treats it as suspend, never failure.
  """
  @callback run_turn(session(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:paused, map()} | {:error, term()}

  @doc "Tear the session down. Must be idempotent and never raise."
  @callback stop_session(session()) :: :ok

  @doc "Canonicalize a raw backend event map (usage, rate limits)."
  @callback normalize_event(map()) :: map()

  @doc "Deliver an Executor message into the live session."
  @callback send_operator_message(session(), CodingAgent.operator_payload()) ::
              {:ok, request_id :: integer()} | {:error, term()}

  @doc """
  Out-of-band interrupt of the live process (optional; implemented by
  the persistent-REPL adapter, which is cut via Ctrl+C into its pane).
  """
  @callback interrupt(session()) :: :ok | {:error, term()}

  @optional_callbacks interrupt: 1
end

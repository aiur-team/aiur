defmodule Aiur.AgentEvents do
  @moduledoc """
  Canonical payload contracts for per-agent and orchestrator-wide PubSub events.

  Subscribers (opencode relay, agent-list pane, future MCP bridges) match
  on these tuple shapes. Producers (`AgentRunner`, `Orchestrator`, `AgentChat`,
  `Alerts`) construct messages with the constructor helpers in this module so
  the wire format stays consistent.

  Topic conventions:
    * `"agent:<identifier>"` carries `t:transcript_message/0` and `t:alert_message/0`
    * `"agents:running"` carries `t:running_change_message/0`
    * `"agents:status"` carries `t:status_change_message/0`
  """

  @typedoc "Stable per-agent identifier (the issue id string)."
  @type agent_identifier :: String.t()

  @typedoc """
  Origin of a transcript line. `:user` and `:assistant` are
  conversational turns; `:system` covers contextual/external information
  (intro, errors, status); `:command` is a shell/tool command the agent
  issues; `:alert` is an Executor-facing notification.
  """
  @type role :: :user | :assistant | :system | :command | :alert | :reasoning | :tool

  @typedoc "One line of an agent conversation transcript."
  @type transcript_event :: %{
          role: role(),
          body: String.t(),
          timestamp: DateTime.t(),
          msg_id: String.t() | nil,
          sequence: integer(),
          turn_id: String.t() | nil,
          payload: map() | nil
        }

  @typedoc "Alert payload broadcast on the per-agent topic."
  @type alert_event :: %{
          name: String.t(),
          message: String.t(),
          reason: String.t(),
          severity: String.t(),
          needs_attention: boolean(),
          sound: String.t() | nil,
          source_ticket_id: String.t() | nil,
          timestamp: DateTime.t()
        }

  @typedoc """
  Summary row used to render the agent list.

    * `:status` — `:running` (a Aiur agent slot is actively running
      this ticket) or `:queued` (the ticket carries an `agent:*` label
      but no slot is allocated).
  """
  @type agent_summary :: %{
          required(:identifier) => agent_identifier(),
          required(:status) => :running | :queued | atom(),
          required(:alert_count) => non_neg_integer(),
          optional(:tag) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:runtime_seconds) => non_neg_integer(),
          optional(:turn_count) => non_neg_integer(),
          optional(:work_state) => atom() | String.t(),
          optional(:pause_reason) => atom() | String.t(),
          optional(:tracker_paused) => boolean(),
          optional(:tracker_identity) => Aiur.TrackerIdentity.t(),
          optional(:backend) => String.t(),
          optional(:model) => String.t()
        }

  @type transcript_message :: {:transcript_event, transcript_event()}
  @type alert_message :: {:alert, alert_event()}
  @type control_lifecycle_message :: {:control_lifecycle, map()}
  @type running_change_message :: {:running_changed, [agent_summary()]}
  @type status_change_message :: {:status_changed, %{identifier: agent_identifier(), status: atom()}}

  @typedoc "Any message that may be received on a Aiur agent topic."
  @type message ::
          transcript_message()
          | alert_message()
          | control_lifecycle_message()
          | running_change_message()
          | status_change_message()

  @doc """
  Canonical short tag name for a transcript role. Used by the
  opencode transcript relay, the per-issue log writer (`Aiur.IssueLog`),
  and any external consumer that wants to
  surface the same labels Aiur renders in its UI. Define every new
  role's tag here so the pane, the file log, and the system log all
  stay in sync.

  Tag-to-meaning map:
    * `agent`     — `:assistant` — words from the agent
    * `user`      — `:user`      — Executor’s typed message
    * `sys`       — `:system`    — external context (intro, errors)
    * `cmd`       — `:command`   — commands the agent runs
    * `alert`     — `:alert`     — Executor-facing notifications
    * `reasoning` — `:reasoning` — agent reasoning / thinking blocks
    * `tool`      — `:tool`      — non-shell tool calls (MCP, file edits)
  """
  @spec tag_name(role()) :: String.t()
  def tag_name(:reasoning), do: "reasoning"
  def tag_name(:tool), do: "tool"
  def tag_name(:assistant), do: "agent"
  def tag_name(:user), do: "user"
  def tag_name(:system), do: "sys"
  def tag_name(:command), do: "cmd"
  def tag_name(:alert), do: "alert"

  @doc """
  Bracketed display form of a tag — `"[agent]"`, `"[usr]"`, etc.
  """
  @spec tag_display(role()) :: String.t()
  def tag_display(role), do: "[" <> tag_name(role) <> "]"

  @spec transcript_event(role(), String.t(), keyword()) :: transcript_event()
  def transcript_event(role, body, opts \\ [])
      when role in [:user, :assistant, :system, :command, :alert, :reasoning, :tool] and
             is_binary(body) do
    %{
      role: role,
      body: body,
      timestamp: Keyword.get(opts, :timestamp) || DateTime.utc_now(),
      msg_id: Keyword.get(opts, :msg_id),
      sequence: Keyword.get(opts, :sequence) || :erlang.unique_integer([:positive, :monotonic]),
      turn_id: Keyword.get(opts, :turn_id),
      payload: Keyword.get(opts, :payload)
    }
  end

  @spec alert_event(String.t(), String.t(), keyword()) :: alert_event()
  def alert_event(name, message, opts \\ []) when is_binary(name) and is_binary(message) do
    %{
      name: name,
      message: message,
      reason: Keyword.get(opts, :reason) || message,
      severity: Keyword.get(opts, :severity) || "info",
      needs_attention: Keyword.get(opts, :needs_attention) == true,
      sound: Keyword.get(opts, :sound),
      source_ticket_id: Keyword.get(opts, :source_ticket_id),
      timestamp: Keyword.get(opts, :timestamp) || DateTime.utc_now()
    }
  end

  @spec agent_summary(agent_identifier(), atom(), non_neg_integer()) :: agent_summary()
  def agent_summary(identifier, status, alert_count)
      when is_binary(identifier) and is_atom(status) and is_integer(alert_count) and alert_count >= 0 do
    %{identifier: identifier, status: status, alert_count: alert_count}
  end

  @doc """
  Build an `agent_summary` map and merge in the optional `extras`
  fields (`:tag`, `:title`, `:runtime_seconds`, `:turn_count`,
  `:work_state`, `:pause_reason`, `:tracker_paused`, `:tracker_identity`,
  `:backend`, `:model`).
  Extras with `nil` values are
  filtered so callers can unconditionally pass `Map.get(entry, :title)`
  (or an unpinned `CodingAgent.model_for/1`) without polluting the
  summary.
  """
  @spec agent_summary(agent_identifier(), atom(), non_neg_integer(), map()) :: agent_summary()
  def agent_summary(identifier, status, alert_count, extras)
      when is_binary(identifier) and is_atom(status) and is_integer(alert_count) and
             alert_count >= 0 and is_map(extras) do
    base = %{identifier: identifier, status: status, alert_count: alert_count}
    Map.merge(base, Enum.reject(extras, fn {_k, v} -> is_nil(v) end) |> Map.new())
  end

  @doc """
  Canonical emoji for a worker's `work_state`. Shared by every
  surface that paints agent status — the agent-list pane, opencode
  relay metadata, and (in future) the web dashboard. If a surface needs
  a different glyph for the same state it should still branch off this
  function so a state-rename is a one-line change.

  Mapping:
    * `:working`     — `🟢` actively working
    * `:paused`      — `⏸️` paused
    * `:error`       — `🔴` agent reported an error
    * `:done`        — `🏁` agent has fully finished (turn-completion broadcast reason)
    * `:deactivated` — `🏁` agent has stopped working for this iteration; ticket lives at 100% awaiting reactivation (PR comment, chat input, pause/resume, or label flip back to an active state)
    * `:completed`   — `⏹️` the runner crossed its final turn boundary and is awaiting replacement or teardown
    * `:sleeping`    — `💤` the agent's chat-completion stream idle-closed (the watchdog saw no transcript activity for its inactivity window); the slot is still held and the next turn flips it back to `:working`
    * anything else (queued, idle, unknown) — `⚫` no live work state
  """
  @spec state_emoji(atom() | String.t() | nil) :: String.t()
  def state_emoji(:working), do: "🟢"
  def state_emoji("working"), do: "🟢"
  def state_emoji(:paused), do: "⏸️"
  def state_emoji("paused"), do: "⏸️"
  def state_emoji(:error), do: "🔴"
  def state_emoji("error"), do: "🔴"
  def state_emoji(:done), do: "🏁"
  def state_emoji("done"), do: "🏁"
  def state_emoji(:deactivated), do: "🏁"
  def state_emoji("deactivated"), do: "🏁"
  def state_emoji(:completed), do: "⏹️"
  def state_emoji("completed"), do: "⏹️"
  def state_emoji(:sleeping), do: "💤"
  def state_emoji("sleeping"), do: "💤"
  def state_emoji(_), do: "⚫"

  @doc """
  Maps an orchestrator snapshot row to the five Stream Deck fleet buckets.

  The mapping deliberately has one home beside the canonical `work_state`
  semantics above, so the grid cannot drift from the agent-list meaning of
  `:working`, `:paused`, `:sleeping`, and the terminal states.

    * `:alert` — unresolved operator attentions (`open_decision_count > 0`)
      take priority because the Executor needs to act.
    * `:stuck` — retrying, errored, or watchdog-unresponsive work needs
      intervention before ordinary live work.
    * `:running` — a live, non-quiescent orchestrator slot is actively working.
    * `:paused` — explicit pauses and quiescent live states (`:sleeping`,
      `:done`, `:deactivated`, and `:completed`) hold work without active
      progress.
    * `:queued` — all remaining tracker-active rows have no live slot; their
      dependency readiness is projected separately.
  """
  @spec streamdeck_bucket(map()) :: :alert | :stuck | :running | :paused | :queued
  def streamdeck_bucket(%{} = agent) do
    work_state = Map.get(agent, :work_state)

    cond do
      positive_integer?(Map.get(agent, :open_decision_count)) -> :alert
      Map.get(agent, :streamdeck_source) == :retrying -> :stuck
      work_state == :error -> :stuck
      Map.get(agent, :waiting_reason) == :unresponsive -> :stuck
      Map.get(agent, :tracker_paused) == true -> :paused
      work_state in [:paused, :sleeping, :done, :deactivated, :completed] -> :paused
      Map.get(agent, :streamdeck_source) == :running -> :running
      true -> :queued
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  @spec agent_topic(agent_identifier()) :: String.t()
  def agent_topic(identifier) when is_binary(identifier), do: "agent:" <> identifier

  @spec running_topic() :: String.t()
  def running_topic, do: "agents:running"

  @spec status_topic() :: String.t()
  def status_topic, do: "agents:status"

  @spec poll_state_topic() :: String.t()
  def poll_state_topic, do: "orchestrator:poll_state"
end

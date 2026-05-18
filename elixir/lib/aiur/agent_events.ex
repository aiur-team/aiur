defmodule Aiur.AgentEvents do
  @moduledoc """
  Canonical payload contracts for per-agent and orchestrator-wide PubSub events.

  Subscribers (CLI conversation panes, agent-list pane, future MCP bridges) match
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
  issues; `:alert` is an operator-facing notification.
  """
  @type role :: :user | :assistant | :system | :command | :alert

  @typedoc "One line of an agent conversation transcript."
  @type transcript_event :: %{
          role: role(),
          body: String.t(),
          timestamp: DateTime.t(),
          msg_id: String.t() | nil
        }

  @typedoc "Alert payload broadcast on the per-agent topic."
  @type alert_event :: %{
          name: String.t(),
          message: String.t(),
          sound: String.t() | nil,
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
          optional(:work_state) => atom() | String.t()
        }

  @type transcript_message :: {:transcript_event, transcript_event()}
  @type alert_message :: {:alert, alert_event()}
  @type running_change_message :: {:running_changed, [agent_summary()]}
  @type status_change_message :: {:status_changed, %{identifier: agent_identifier(), status: atom()}}

  @typedoc "Any message that may be received on a Aiur agent topic."
  @type message ::
          transcript_message() | alert_message() | running_change_message() | status_change_message()

  @doc """
  Canonical short tag name for a transcript role. Used by the
  conversation pane (`AiurPane.Viewport`), the per-issue log writer
  (`Aiur.IssueLog`), and any external consumer that wants to
  surface the same labels Aiur renders in its UI. Define every new
  role's tag here so the pane, the file log, and the system log all
  stay in sync.

  Tag-to-meaning map:
    * `agent` — `:assistant` — words from the agent
    * `user`  — `:user`      — operator's typed message
    * `sys`   — `:system`    — external context (intro, errors)
    * `cmd`   — `:command`   — commands the agent runs
    * `alert` — `:alert`     — operator-facing notifications
  """
  @spec tag_name(role()) :: String.t()
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
      when role in [:user, :assistant, :system, :command, :alert] and is_binary(body) do
    %{
      role: role,
      body: body,
      timestamp: Keyword.get(opts, :timestamp) || DateTime.utc_now(),
      msg_id: Keyword.get(opts, :msg_id)
    }
  end

  @spec alert_event(String.t(), String.t(), keyword()) :: alert_event()
  def alert_event(name, message, opts \\ []) when is_binary(name) and is_binary(message) do
    %{
      name: name,
      message: message,
      sound: Keyword.get(opts, :sound),
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
  `:work_state`). Extras with `nil` values are filtered so callers can
  unconditionally pass `Map.get(entry, :title)` without polluting the
  summary.
  """
  @spec agent_summary(agent_identifier(), atom(), non_neg_integer(), map()) :: agent_summary()
  def agent_summary(identifier, status, alert_count, extras)
      when is_binary(identifier) and is_atom(status) and is_integer(alert_count) and
             alert_count >= 0 and is_map(extras) do
    base = %{identifier: identifier, status: status, alert_count: alert_count}
    Map.merge(base, Enum.reject(extras, fn {_k, v} -> is_nil(v) end) |> Map.new())
  end

  @spec agent_topic(agent_identifier()) :: String.t()
  def agent_topic(identifier) when is_binary(identifier), do: "agent:" <> identifier

  @spec running_topic() :: String.t()
  def running_topic, do: "agents:running"

  @spec status_topic() :: String.t()
  def status_topic, do: "agents:status"
end

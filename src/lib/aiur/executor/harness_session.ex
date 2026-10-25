defmodule Aiur.Executor.HarnessSession do
  @moduledoc """
  Which coding-agent harness session is the live Executor.

  The environment variable names are the whole contract with the harnesses and
  live only here. `CLAUDE_CODE_SESSION_ID` is documented; `CLAUDE_CONFIG_DIR`,
  `CLAUDE_PID` and `CLAUDE_CODE_CHILD_SESSION` were observed on Claude Code
  2.1.296 and are not. `CODEX_THREAD_ID` is injected by Codex into tool shells.

  `detect/1` is pure: the CLI reads its own environment and ships it over RPC,
  because the daemon's environment says nothing about the caller's.
  """

  alias Aiur.Executor.Claims

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @harnesses ["claude", "codex"]

  @doc "The session described by `env`, or `nil` for a subagent or an environment with no usable session."
  @spec detect(map()) :: map() | nil
  def detect(env) do
    cond do
      present(env["CLAUDE_CODE_CHILD_SESSION"]) -> nil
      id = present(env["CODEX_THREAD_ID"]) -> build("codex", id, env)
      id = present(env["CLAUDE_CODE_SESSION_ID"]) -> build("claude", id, env)
      true -> nil
    end
  end

  @doc """
  Session to record for a CLI invocation: an explicit `:session_id` (with optional
  `:harness`, default `claude`) wins over the environment in `:env`, a list of
  `{name, base64_value}` pairs.
  """
  @spec resolve(keyword()) :: map() | nil
  def resolve(opts) do
    env = Map.new(Keyword.get(opts, :env, []), fn {key, value} -> {key, Base.decode64!(value)} end)

    case Keyword.get(opts, :session_id) do
      nil -> detect(env)
      id -> build(Keyword.get(opts, :harness) || "claude", id, env)
    end
  end

  @doc """
  Adds the session to an owner's claim `entry` (additive field); any other role gets nothing.

  A new session (`:session`, or `:session_opts` resolved by `resolve/1`) replaces the old one. The
  consumer's previous session is carried over only across a renewal within a live lease: a claim
  after a lapse must not inherit a handle that may name another conversation.
  """
  @spec record(map(), keyword(), map(), DateTime.t()) :: map()
  def record(%{"role" => "owner"} = entry, opts, existing, now) do
    carried = if Claims.live?(existing, now), do: existing["session"]
    session = Keyword.get(opts, :session) || resolve(Keyword.get(opts, :session_opts, [])) || carried
    if is_map(session), do: Map.put(entry, "session", Map.put_new(session, "recorded_at", DateTime.to_iso8601(now))), else: entry
  end

  def record(entry, _opts, _existing, _now), do: entry

  @doc "Whether `value` is an acceptable session id."
  @spec valid_session_id?(term()) :: boolean()
  def valid_session_id?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  @doc "Whether `value` names a supported harness."
  @spec valid_harness?(term()) :: boolean()
  def valid_harness?(value), do: value in @harnesses

  @doc """
  The live Executor's session handle, or `%{"state" => "unknown", "reason" => ...}`.

  A handle whose `harness_pid` is dead, or whose owner's lease has lapsed, is not
  trusted: forking a stale session would resume the wrong conversation.
  """
  @spec current(keyword()) :: map()
  def current(opts \\ []) do
    case Claims.owner(opts) do
      :none -> unknown("no_live_owner")
      {:ok, %{"session" => %{"harness_pid" => pid} = session}} when is_integer(pid) -> if alive?(pid), do: live(session), else: unknown("harness_pid_dead")
      {:ok, %{"session" => %{} = session}} -> live(session)
      {:ok, _owner} -> unknown("no_session")
    end
  end

  defp build(harness, id, env) do
    if valid_session_id?(id) and valid_harness?(harness) do
      # Env-derived pid/config belong to the *current* session only.
      claude? = harness == "claude" and env["CLAUDE_CODE_SESSION_ID"] in [nil, "", id]

      %{
        "harness" => harness,
        "session_id" => id,
        "config_dir" => (claude? && present(env["CLAUDE_CONFIG_DIR"])) || nil,
        "cwd" => present(env["PWD"]),
        "harness_pid" => (claude? && parse_pid(env["CLAUDE_PID"])) || nil
      }
    end
  end

  defp live(session), do: Map.put(session, "state", "live")
  defp unknown(reason), do: %{"state" => "unknown", "reason" => reason}

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp parse_pid(value) do
    case Integer.parse(value || "") do
      {pid, ""} when pid > 0 -> pid
      _invalid -> nil
    end
  end

  defp alive?(pid), do: match?({_output, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
end

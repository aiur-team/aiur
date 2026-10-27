defmodule VoiceConverse.AgentFork.Handle do
  @moduledoc """
  The session handle of the agent that started `talk`, read from the environment its shell tool
  passes down. This is the only place that knows the agent CLIs' environment variable names:
  `CODEX_THREAD_ID` is source-verified only, so a rename must break one test, not the feature.
  """

  @type harness :: :claude_code | :codex | :opencode | :other
  @type t :: %{harness: harness(), session_id: String.t() | nil, cwd: Path.t(), config_dir: Path.t() | nil}

  # Claude Code: documented in Bash tool subprocesses.
  @claude_session "CLAUDE_CODE_SESSION_ID"
  @claude_config "CLAUDE_CONFIG_DIR"
  # Codex: injected into tool shells (source-verified, not in user docs).
  @codex_thread "CODEX_THREAD_ID"
  @codex_home "CODEX_HOME"

  # Set in a Claude Code tool shell; a nested `claude` that sees them takes itself for a child
  # of the parent session.
  @claude_markers ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]

  @claude_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @codex_id ~r/\A[0-9a-f-]+\z/i

  @doc "Names of the variables that tie a process to its parent session. A fork's child env drops them."
  @spec parent_env_names() :: [String.t()]
  def parent_env_names, do: [@claude_session, @codex_thread | @claude_markers]

  @doc """
  Whether `id` has the shape of a session id of `harness` (a UUID for Claude Code, hex and dashes
  for Codex). The id goes into argv, so anything else, such as `--some-flag`, is refused.
  """
  @spec valid_session_id?(harness(), term()) :: boolean()
  def valid_session_id?(:claude_code, id) when is_binary(id), do: Regex.match?(@claude_id, id)
  def valid_session_id?(:codex, id) when is_binary(id), do: Regex.match?(@codex_id, id)
  def valid_session_id?(_harness, _id), do: false

  @doc """
  Reads the handle from `env`. When both a Claude Code and a Codex session id are present the
  nearer agent is unknown, so the result is `{:error, :ambiguous_handle}` instead of a guess.
  """
  @spec discover(%{optional(String.t()) => String.t()}, Path.t()) ::
          {:ok, t()} | {:error, :no_handle | :ambiguous_handle | :invalid_handle}
  def discover(env \\ System.get_env(), cwd \\ File.cwd!()) do
    case {present(env, @claude_session), present(env, @codex_thread)} do
      {nil, nil} -> {:error, :no_handle}
      {id, nil} -> handle(:claude_code, id, cwd, present(env, @claude_config))
      {nil, id} -> handle(:codex, id, cwd, present(env, @codex_home))
      {_, _} -> {:error, :ambiguous_handle}
    end
  end

  defp handle(harness, id, cwd, config_dir) do
    if valid_session_id?(harness, id),
      do: {:ok, %{harness: harness, session_id: id, cwd: cwd, config_dir: config_dir}},
      else: {:error, :invalid_handle}
  end

  defp present(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end

defmodule Aiur.Config.CodexRuntime do
  @moduledoc false

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.Codex, as: CodexSchema

  @doc """
  The IANA zone Codex usage-limit reset text is read in
  (`agent.codex.reset_time_zone`), or `:local` for the daemon host's zone.
  """
  @spec codex_reset_time_zone() :: String.t() | :local
  def codex_reset_time_zone do
    case Aiur.Config.settings() do
      {:ok, %{agent: %{codex: %{reset_time_zone: zone}}}} when is_binary(zone) -> zone
      _ -> :local
    end
  end

  @doc """
  The least time Aiur waits before it resumes a worker whose Codex usage-limit
  text names a reset that already passed (`agent.codex.reset_min_delay_seconds`).
  """
  @spec codex_reset_min_delay_seconds() :: pos_integer()
  def codex_reset_min_delay_seconds do
    case Aiur.Config.settings() do
      {:ok, %{agent: %{codex: %{reset_min_delay_seconds: seconds}}}} when is_integer(seconds) and seconds > 0 -> seconds
      _ -> 300
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(Aiur.Config.settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, Aiur.Config.codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- Aiur.Config.settings(),
         {:ok, approval_policy} <-
           validate_codex_approval_policy(settings.agent.codex.approval_policy),
         {:ok, turn_sandbox_policy} <- codex_runtime_turn_sandbox_policy(settings, workspace, opts) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: settings.agent.codex.thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp codex_runtime_turn_sandbox_policy(settings, workspace, opts) do
    with {:ok, policy} <- Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
      Enum.reduce_while(Application.get_env(:aiur, :turn_sandbox_root_contributors, []), {:ok, policy}, &contribute_sandbox_roots(&1, &2, settings, opts))
    end
  end

  defp contribute_sandbox_roots(contributor, {:ok, policy}, settings, opts) do
    case contributor.contribute(policy, settings, opts) do
      {:ok, policy} -> {:cont, {:ok, policy}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp validate_codex_approval_policy(value) do
    case CodexSchema.validate_approval_policy(value) do
      {:ok, trimmed} -> {:ok, trimmed}
      {:error, _message} -> {:error, {:invalid_codex_approval_policy, value}}
    end
  end
end

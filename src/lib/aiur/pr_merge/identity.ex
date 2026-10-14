defmodule Aiur.PrMerge.Identity do
  @moduledoc false
  alias Aiur.GitHub.Config, as: GitHubConfig

  @spec guard(map(), String.t(), String.t() | nil) :: :ok | {:refuse, [String.t()]}
  def guard(settings, cwd, agent_bin \\ System.get_env("AIUR_AGENT_BIN")) do
    with true <- is_nil(agent_bin),
         {:ok, cwd} <- Aiur.PathSafety.canonicalize(cwd),
         {:ok, root} <- Aiur.PathSafety.canonicalize(settings.workspace.root),
         false <- cwd == root or String.starts_with?(cwd, root <> "/") do
      :ok
    else
      _ -> {:refuse, ["operator command cannot run inside an agent workspace"]}
    end
  end

  @spec allowed(map(), map()) :: :ok | {:refuse, [String.t()]}
  def allowed(%{"login" => login, "type" => "User"}, github) when is_binary(login) do
    excluded = Enum.reject([github.bot_account, github.github_app.account], &is_nil/1)

    if not Enum.any?(excluded, &(String.downcase(&1) == String.downcase(login))) and
         GitHubConfig.human_merger_allowed?(login, github.human_mergers),
       do: :ok,
       else: {:refuse, ["identity #{login} must be an operator in tracker.github.human_mergers, never the bot or App"]}
  end

  def allowed(_user, _github), do: {:refuse, ["GitHub identity is not a human user"]}

  @spec token() :: {:ok, String.t()} | {:error, String.t()}
  def token do
    case Aiur.AgentGitHubGuard.real_gh() do
      nil -> {:error, "gh is not installed"}
      gh -> read_token(gh)
    end
  end

  defp validate_token(token) do
    if token != "" and not String.match?(token, ~r/\s/), do: {:ok, token}, else: {:error, "invalid operator credential"}
  end

  defp read_token(gh) do
    case System.cmd(gh, ["auth", "token", "--hostname", "github.com"], env: [{"GH_TOKEN", nil}, {"GITHUB_TOKEN", nil}], stderr_to_stdout: true) do
      {token, 0} -> validate_token(String.trim(token))
      {_output, _status} -> {:error, "cannot read operator gh credential; sign in as a human merger"}
    end
  end
end

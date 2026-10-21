defmodule Aiur.GitHub.AccessSettings do
  @moduledoc false
  @behaviour Aiur.GitHub.Access.SettingsProvider

  alias Aiur.Config
  alias Aiur.Config.Schema.Agent
  alias Aiur.GitHub.Access.Settings
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Credential
  alias Aiur.RepoBase
  alias Aiur.Workspace.Layout

  @impl true
  def settings do
    config = safely(fn -> Config.settings!() end, nil)
    github = if config, do: config.tracker.github, else: %{}
    repo = safely(&GitHubConfig.repo/0, nil)
    quota_dir = if is_binary(repo) and repo != "", do: Path.join(RepoBase.repo_path(repo), "github-quota")

    %Settings{
      state_root: decision_root(),
      budget_dir: budget_dir(),
      budget_enabled?: Application.get_env(:aiur, :github_budget_enabled?, true),
      budget: if(is_struct(github), do: plain(github), else: %{}),
      repo: repo,
      app_account: get_in(plain(github), [:github_app, :account]),
      bot_account: Map.get(github, :bot_account),
      credentials: github |> Map.get(:credentials, []) |> Enum.reject(&(&1.enabled == false)) |> Enum.map(&credential/1),
      quota_dir: quota_dir,
      request_log_dir: if(Application.get_env(:aiur, :env) != :test, do: quota_dir),
      resource_store_path: resource_store_path(),
      probe_dir: safely(fn -> Config.workspace_root() |> Path.expand() |> Layout.issue_workspace_path("__github_quota_probe__") end, nil),
      cache: %{
        ttls: Application.get_env(:aiur, :github_read_cache_ttls, %{}),
        max_body_bytes: Application.get_env(:aiur, :github_resource_store_max_body_bytes)
      },
      broker_timeout: broker_timeout(config)
    }
  end

  defp budget_dir do
    case System.get_env("AIUR_DEV_TEST_TICKET_IDS") do
      scope when is_binary(scope) ->
        case System.get_env("AIUR_GITHUB_BUDGET_DIR") do
          path when is_binary(path) and path != "" -> Path.expand(path)
          _ -> raise ArgumentError, "AIUR_GITHUB_BUDGET_DIR must name a per-launch sandbox budget directory"
        end

      _ ->
        default_budget_dir(Application.get_env(:aiur, :github_budget_dir))
    end
  end

  defp default_budget_dir(path) when is_binary(path) do
    if String.trim(path) != "", do: Path.expand(path), else: default_budget_dir(nil)
  end

  defp default_budget_dir(_path), do: Path.join(System.user_home!(), ".aiur/github-budget")

  defp decision_root do
    case Config.Paths.decision_state_dir() do
      {:ok, dir} -> dir
      {:error, _reason} -> nil
    end
  end

  defp resource_store_path do
    case Application.get_env(:aiur, :github_resource_store_path) do
      path when is_binary(path) and path != "" -> path
      _ -> if dir = decision_root(), do: Path.join(dir, "github_resources.json")
    end
  end

  defp broker_timeout(config) do
    defaults = %Agent{}

    Map.new(Map.keys(%Settings{state_root: nil}.broker_timeout), fn field ->
      value = if config, do: Map.get(config.agent, field)
      {field, if(is_integer(value) and value > 0, do: value, else: Map.fetch!(defaults, field))}
    end)
  end

  defp credential(entry) do
    %Credential{
      id: entry.id,
      kind: String.to_existing_atom(entry.kind),
      identity: entry.identity,
      token_env: entry.token_env,
      source: if(entry.kind == "app_installation", do: :app, else: :env),
      writes?: entry.writes == true and entry.kind != "human"
    }
  end

  defp plain(value) when is_struct(value), do: value |> Map.from_struct() |> plain()
  defp plain(value) when is_map(value), do: Map.new(value, fn {key, item} -> {key, plain(item)} end)
  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value), do: value

  defp safely(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end
end

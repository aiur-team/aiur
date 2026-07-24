defmodule Aiur.Init.Runtime do
  @moduledoc """
  Composition-root helpers for a live `aiur init` run (HTTP client start, toolchain detection, first warm-base build, config readback).
  """

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage
  alias Aiur.Codeowners
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Init.Alerts
  alias Aiur.Init.Format
  alias Aiur.Init.Migration
  alias Aiur.Init.Prompt
  alias Aiur.Init.Scaffold
  alias Aiur.Init.Templates
  alias Aiur.Prewarm.Detect
  alias Aiur.RepoBase

  @type io :: %{
          puts: (IO.chardata() -> :ok),
          input: (String.t(), String.t() | nil, String.t() | nil -> String.t() | nil),
          select: (String.t(), [String.t()], String.t() -> String.t()),
          multiselect: (String.t(), [String.t()], [String.t()] -> [String.t()]),
          confirm: (String.t(), boolean() -> boolean())
        }

  @type deps :: %{
          config_target: (atom() -> Path.t()),
          legacy_config_target: (atom() -> Path.t()),
          existing_config_path: (Path.t() -> String.t() | nil),
          load_config: (Path.t() -> {:ok, map()} | {:error, term()}),
          migrate_layout: (map() -> {:ok, map()} | {:error, term()}),
          read_example: (-> String.t()),
          detect_repo: (-> String.t() | nil),
          detect_toolchain: (-> Detect.result()),
          prewarm_build: (String.t(), String.t() -> {:ok, Path.t()} | {:error, term()}),
          global_alerts_path: (-> Path.t()),
          existing_alerts_path: (Path.t() -> String.t() | nil),
          write_config: (Path.t(), String.t() -> {:ok, Path.t()} | {:error, term()}),
          append_config: (Path.t(), iodata() -> {:ok, Path.t()} | {:error, term()}),
          ensure_prompt_file: (Path.t(), String.t(), String.t() | nil -> {:created | :exists, Path.t()}),
          ensure_aiurhooks: (Path.t() -> {:created | :exists, Path.t()}),
          ensure_alerts: (Path.t(), Path.t() | nil -> {:created | :exists, Path.t()}),
          ensure_prewarm_file: (Path.t(), String.t() -> {:created | :exists, Path.t()}),
          add_gitignore_entry: (String.t() -> {:added | :exists, Path.t()}),
          ensure_env: (String.t() -> {:created | :exists, Path.t()}),
          check_agent_auth: (String.t() -> :ok | {:error, String.t()}),
          install_claude_app_server: (-> :ok | {:error, String.t()}),
          claude_version: (-> {:ok, String.t()} | {:error, String.t()}),
          repo_root: (-> Path.t()),
          github_login: (-> String.t() | nil),
          github_bot_account_default: (-> String.t() | nil),
          github_token: (-> String.t() | nil),
          discover_models: ([String.t()] -> map()),
          list_labels: (map() -> {:ok, [String.t()]} | {:error, term()}),
          create_labels: (map(), [String.t()] -> :ok | {:error, String.t()})
        }

  @spec runtime_io() :: io()
  def runtime_io do
    %{
      puts: fn message -> IO.puts(message) end,
      input: fn label, default, hint ->
        case Prompt.input(label, default, hint: hint) do
          "" -> default
          value -> value
        end
      end,
      select: fn label, options, default ->
        Prompt.select(label, options, default, render: &Format.dim_help/1)
      end,
      multiselect: fn label, options, defaults -> Prompt.multiselect(label, options, defaults) end,
      confirm: fn label, default ->
        Prompt.select(label, ["Yes", "No"], if(default, do: "Yes", else: "No")) == "Yes"
      end
    }
  end

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      config_target: &Scaffold.config_target/1,
      legacy_config_target: &Scaffold.legacy_config_target/1,
      existing_config_path: &Scaffold.existing_config_path/1,
      load_config: &load_config/1,
      migrate_layout: &Migration.migrate_layout/1,
      read_example: fn -> Templates.config_example() end,
      detect_repo: &Aiur.Init.GitHub.detect_repo/0,
      detect_toolchain: &detect_toolchain/0,
      prewarm_build: &run_first_prewarm/2,
      global_alerts_path: &Scaffold.global_alerts_path/0,
      existing_alerts_path: &Scaffold.existing_alerts_path/1,
      write_config: &Scaffold.write_config/2,
      append_config: &Scaffold.append_config_section/2,
      ensure_prompt_file: &Scaffold.write_prompt_file/3,
      ensure_aiurhooks: &Scaffold.write_aiurhooks/1,
      ensure_alerts: &Alerts.write_alerts_file/2,
      ensure_prewarm_file: &Scaffold.write_prewarm_file/2,
      add_gitignore_entry: &Scaffold.add_gitignore_entry/1,
      ensure_env: &Scaffold.ensure_env/1,
      check_agent_auth: &Aiur.Init.AgentCli.check_agent_auth/1,
      install_claude_app_server: &Aiur.Init.AgentCli.install_claude_app_server/0,
      claude_version: &Aiur.Init.AgentCli.claude_version/0,
      repo_root: fn -> Codeowners.repo_root(File.cwd!()) end,
      github_login: &Aiur.Init.GitHub.detect_github_login/0,
      github_bot_account_default: &Aiur.Init.GitHub.detect_bot_account/0,
      github_token: &GitHubConfig.token/0,
      discover_models: &Aiur.ModelCatalog.discover/1,
      list_labels: &Aiur.Init.GitHub.list_repo_labels/1,
      create_labels: &Aiur.Init.GitHub.create_labels/2
    }
  end

  # `aiur init` boots interactively without the OTP app started, so the Req /
  # Finch HTTP client the GitHub label calls rely on isn't running yet. Start
  # it up front so a token-present run reaches tag creation instead of crashing.
  @spec ensure_http_client() :: :ok
  def ensure_http_client do
    Application.ensure_all_started(:req)
    :ok
  end

  @spec load_config(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_config(target) do
    case Aiur.Workflow.load(target) do
      {:ok, loaded} -> {:ok, loaded.config}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec detect_toolchain() :: Detect.result()
  def detect_toolchain, do: Detect.detect(File.cwd!())

  @spec run_first_prewarm(String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def run_first_prewarm(url, command) do
    RepoBase.refresh(RepoBase.base_path(url), url, command)
  end
end

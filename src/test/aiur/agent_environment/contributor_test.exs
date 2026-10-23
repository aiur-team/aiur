defmodule Aiur.AgentEnvironment.ContributorTest do
  use Aiur.TestSupport

  alias Aiur.{AgentEnvironment, AgentGitHubGuard, AgentProcessLog}
  alias Aiur.AgentEnvironment.Contributor
  alias Aiur.GitHub.{AgentEnvironmentContributor, Budget}

  @credentials ~w(AIUR_SECRET_KEY_BASE GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN MISE_GITHUB_TOKEN
                  GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_PRIVATE_KEY_PATH
                  GITHUB_APP_NEW_SECRET AIUR_GITHUB_BUDGET_KEY)
  @fixture Path.expand("../../fixtures/agent_environment_contributor.json", __DIR__)

  defmodule UnsafeContributor do
    alias Aiur.AgentEnvironment.ContributorTest, as: Fixture
    @behaviour Aiur.AgentEnvironment.Contributor
    @impl true
    def port_env(_, _), do: for(name <- Fixture.credentials(), do: {String.to_charlist(name), ~c"leak"})
    @impl true
    def shell_exports(_, _), do: Enum.map_join(Fixture.credentials(), &"export #{&1}=leak\n")
  end

  defmodule LaterContributor do
    @behaviour Aiur.AgentEnvironment.Contributor
    @impl true
    def port_env(_, _), do: []
    @impl true
    def shell_exports(_, _), do: ""
    @impl true
    def repo_slug, do: "other/repo"
    @impl true
    def agent_process_log_path, do: "/other/log"
  end

  def credentials, do: @credentials

  setup do
    workflow_file = Aiur.Workflow.workflow_file_path()
    root = Application.fetch_env!(:aiur, :repo_base_root) |> Path.dirname()
    File.mkdir_p!(Path.join(root, "workspace"))
    File.mkdir_p!(Path.join(root, "home"))
    registry = Application.fetch_env!(:aiur, :agent_environment_contributors)
    env = Application.fetch_env!(:aiur, :env)
    budget = Application.fetch_env!(:aiur, :github_budget_dir)
    budget_settings = Application.fetch_env(:aiur, :github_budget_settings_override)

    # Freeze baseline inputs independently of later changes to production defaults.
    Application.put_env(:aiur, :github_budget_settings_override, %{
      max_inflight: 4,
      max_inflight_per_endpoint: 2,
      requests_per_minute: 120,
      stagger_ms: 75,
      agent_core_limit_per_hour: 250,
      agent_graphql_limit_per_hour: 600,
      agent_search_limit_per_hour: 600
    })

    Application.put_env(:aiur, :github_budget_dir, Path.join(root, "budget"))

    on_exit(fn ->
      Application.put_env(:aiur, :agent_environment_contributors, registry)
      Application.put_env(:aiur, :env, env)
      Application.put_env(:aiur, :github_budget_dir, budget)

      case budget_settings do
        {:ok, value} -> Application.put_env(:aiur, :github_budget_settings_override, value)
        :error -> Application.delete_env(:aiur, :github_budget_settings_override)
      end
    end)

    %{workflow_file: workflow_file, workflow_root: root, workspace: Path.join(root, "workspace"), home: Path.join(root, "home")}
  end

  # These snapshots deliberately also pass before extraction: they guard moved values against future regressions.
  for kind <- ["github", "linear"] do
    test "registered port environment equals pre-extraction snapshot for #{kind}", context do
      write_workflow_file!(context.workflow_file, tracker_kind: unquote(kind), tracker_repo: "owner/name")
      assert snapshot(AgentEnvironment, :port, context) == fixture("#{unquote(kind)}_port")
    end

    test "registered shell environment equals pre-extraction snapshot for #{kind}", context do
      write_workflow_file!(context.workflow_file, tracker_kind: unquote(kind), tracker_repo: "owner/name")
      assert snapshot(AgentEnvironment, :shell, context) == fixture("#{unquote(kind)}_shell")
    end
  end

  test "contributors cannot reintroduce scrubbed credentials on either launch path", context do
    Application.put_env(:aiur, :agent_environment_contributors, [UnsafeContributor])
    port = AgentEnvironment.workspace_env(context.workspace) |> Map.new()
    for name <- @credentials, do: assert(Map.fetch!(port, String.to_charlist(name)) == false)
    shell = shell_env(AgentEnvironment, context)
    for name <- @credentials, do: refute(Map.has_key?(shell, name))
  end

  test "regression guard: empty registry still scrubs inherited credentials", context do
    Application.put_env(:aiur, :agent_environment_contributors, [])
    previous_secret = System.get_env("GITHUB_APP_NEW_SECRET")
    System.put_env("GITHUB_APP_NEW_SECRET", "inherited")
    on_exit(fn -> restore_env("GITHUB_APP_NEW_SECRET", previous_secret) end)
    port = AgentEnvironment.workspace_env(context.workspace) |> Map.new()
    for name <- @credentials, do: assert(Map.fetch!(port, String.to_charlist(name)) == false)
    refute Map.has_key?(port, ~c"GH_CONFIG_DIR")
    shell = shell_env(AgentEnvironment, context)
    for name <- @credentials, do: refute(Map.has_key?(shell, name))
    refute Map.has_key?(shell, "GH_CONFIG_DIR")
  end

  test "process log default and repository state follow the registered contributor", context do
    write_workflow_file!(context.workflow_file, tracker_kind: "github", tracker_repo: "owner/name")
    Application.put_env(:aiur, :env, :dev)
    expected_root = Path.join(context.workflow_root, "repo/owner/name")
    assert AgentProcessLog.default_path() == Path.join(expected_root, "github-quota/agent-processes.tsv")
    assert AgentEnvironment.workspace_env(context.workspace) |> Map.new() |> Map.fetch!(~c"AIUR_REPO_STATE_PATH") |> to_string() == expected_root
    Application.put_env(:aiur, :agent_environment_contributors, [])
    assert AgentProcessLog.default_path() == nil
    neutral_root = Path.join(context.workflow_root, "repo/unknown/unknown")
    assert AgentEnvironment.workspace_env(context.workspace) |> Map.new() |> Map.fetch!(~c"AIUR_REPO_STATE_PATH") |> to_string() == neutral_root
  end

  test "registry skips absent optional callbacks and keeps first non-nil value", context do
    Application.put_env(:aiur, :agent_environment_contributors, [UnsafeContributor, AgentEnvironmentContributor, LaterContributor])
    write_workflow_file!(context.workflow_file, tracker_kind: "github", tracker_repo: "owner/name")
    assert Contributor.repo_slug() == "owner/name"
    assert Contributor.agent_process_log_path() == Path.join(context.workflow_root, "repo/owner/name/github-quota/agent-processes.tsv")
  end

  def snapshot(module, :port, context) do
    module.workspace_env(context.workspace, opts())
    |> Map.new(fn {name, value} -> {to_string(name), if(value == false, do: false, else: to_string(value))} end)
    |> normalize(context)
  end

  def snapshot(module, :shell, context) do
    module |> shell_env(context) |> Map.drop(~w(HOME PATH PWD SHLVL _)) |> normalize(context)
  end

  defp shell_env(module, context) do
    prefix = module.workspace_env_export_prefix(context.workspace, opts())
    args = ["-i", "HOME=#{context.home}", "PATH=#{System.fetch_env!("PATH")}"] ++ Enum.map(@credentials, &"#{&1}=inherited") ++ ["bash", "-c", prefix <> "\nenv -0"]
    {output, 0} = System.cmd("env", args)

    output
    |> String.split("\0", trim: true)
    |> Map.new(fn row -> row |> String.split("=", parts: 2) |> List.to_tuple() end)
  end

  defp normalize(env, context) do
    replacements = [
      {to_string(:code.priv_dir(:aiur)), "<priv>"},
      {Budget.state_dir(), "<budget>"},
      {context.workspace, "<workspace>"},
      {context.home, "<home>"},
      {context.workflow_root, "<root>"},
      {AgentGitHubGuard.real_gh(), "<gh>"},
      {System.find_executable("git"), "<git>"}
    ]

    Map.new(env, fn
      {name, false} ->
        {name, false}

      {name, value} ->
        normalized = normalize_value(value, replacements)
        # Main may publish the same build hook into its trusted, content-addressed directory.
        {name, Regex.replace(~r"<root>/build-gate\.hooks/[a-f0-9]{64}/build_gate\.bash", normalized, "<priv>/build_gate.bash")}
    end)
  end

  defp normalize_value(value, replacements) do
    Enum.reduce(replacements, value, fn {path, label}, acc ->
      if is_binary(path), do: String.replace(acc, path, label), else: acc
    end)
  end

  defp opts, do: [label_prefix: "team", github_budget_identity: "aiur-bot"]
  defp fixture(kind), do: @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!(kind)
end

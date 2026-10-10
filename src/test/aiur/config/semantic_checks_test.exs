defmodule Aiur.Config.SemanticChecksTest do
  @moduledoc "Legacy validation characterization: these regression guards intentionally pass before extraction."
  use Aiur.TestSupport, async: false

  defmodule GitHubSpy do
    alias Aiur.Tracker.SemanticCheck.Settings
    @behaviour Aiur.Config.SemanticCheck
    @impl true
    def applies?(settings), do: settings.tracker.kind == "github"
    @impl true
    def check(settings) do
      send(self(), :github_check)
      Settings.check(settings)
    end
  end

  defmodule ClaudeSpy do
    @behaviour Aiur.Config.SemanticCheck
    @impl true
    def applies?(settings), do: Aiur.Claude.Config.SemanticCheck.applies?(settings)
    @impl true
    def check(settings) do
      send(self(), :claude_check)
      Aiur.Claude.Config.SemanticCheck.check(settings)
    end
  end

  defmodule OpencodeSpy do
    @behaviour Aiur.Config.SemanticCheck
    @impl true
    def applies?(settings), do: Aiur.Opencode.Config.SemanticCheck.applies?(settings)
    @impl true
    def check(settings) do
      send(self(), :opencode_check)
      Aiur.Opencode.Config.SemanticCheck.check(settings)
    end
  end

  defmodule FailingCheck do
    @behaviour Aiur.Config.SemanticCheck
    @impl true
    def applies?(_settings), do: true
    @impl true
    def check(_settings), do: {:error, :registered_failure}
  end

  defmodule RaisingCheck do
    @behaviour Aiur.Config.SemanticCheck
    @impl true
    def applies?(_settings), do: true
    @impl true
    def check(_settings), do: raise("registered check raised")
  end

  setup do
    registry = Application.fetch_env!(:aiur, :config_semantic_checks)
    on_exit(fn -> Application.put_env(:aiur, :config_semantic_checks, registry) end)
    token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "semantic-check-test-token")
    on_exit(fn -> restore_env("GITHUB_TOKEN", token) end)
    :ok
  end

  test "legacy regression: kind and Linear errors retain their precedence" do
    for {overrides, expected} <- [
          {[tracker_kind: nil], {:error, :missing_tracker_kind}},
          {[tracker_kind: "jira"], {:error, {:unsupported_tracker_kind, "jira"}}},
          {[agent_kind: "unsupported"], {:error, {:unsupported_agent_kind, "unsupported"}}},
          {[tracker_api_token: nil], {:error, :missing_linear_api_token}},
          {[tracker_project_slug: nil], {:error, :missing_linear_project_slug}}
        ] do
      write_workflow_file!(Workflow.workflow_file_path(), overrides)
      assert Config.validate!() == expected
    end
  end

  test "legacy regression: GitHub excludes Claude validation while memory reaches it" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "example/repo", agent_kind: "claude", command: "   ")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude", command: "   ")
    assert {:error, "Claude command missing — set claude.command in .aiur/config"} = Config.validate!()
  end

  test "public validation uses the registered exclusive result and skips always checks on error" do
    Application.put_env(:aiur, :config_semantic_checks, exclusive: [FailingCheck], always: [OpencodeSpy])
    assert {:error, :registered_failure} = Config.validate!()
    refute_received :opencode_check
  end

  test "only the first applicable exclusive check runs; always checks follow it" do
    spy_registry()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "example/repo", agent_kind: "claude")
    assert :ok = Config.validate!()
    assert_received :github_check
    refute_received :claude_check
    assert_received :opencode_check

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    assert :ok = Config.validate!()
    refute_received :github_check
    assert_received :claude_check
    assert_received :opencode_check
  end

  test "sandbox error short-circuits the later Opencode check" do
    spy_registry()
    missing = Path.join(Path.dirname(Workflow.workflow_file_path()), "missing-root")

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: [missing]}
    )

    assert {:error, {:unsafe_turn_sandbox_policy, reason}} = Config.validate!()
    assert inspect(reason) =~ missing
    refute_received :opencode_check
  end

  test "GitHub validation error propagates without reaching Claude or Opencode" do
    spy_registry()
    System.delete_env("GITHUB_TOKEN")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "example/repo", agent_kind: "claude")
    assert {:error, "GitHub token missing — set GITHUB_TOKEN env var"} = Config.validate!()
    assert_received :github_check
    refute_received :claude_check
    refute_received :opencode_check
  end

  test "missing or empty registry fails closed through public validation" do
    Application.delete_env(:aiur, :config_semantic_checks)
    assert {:error, :config_checks_unregistered} = Config.validate!()

    for registry <- [[], [exclusive: [], always: []]] do
      Application.put_env(:aiur, :config_semantic_checks, registry)
      assert {:error, :config_checks_unregistered} = Config.validate!()
    end
  end

  test "registered check exceptions propagate" do
    Application.put_env(:aiur, :config_semantic_checks, exclusive: [RaisingCheck], always: [OpencodeSpy])
    assert_raise RuntimeError, "registered check raised", fn -> Config.validate!() end
    refute_received :opencode_check
  end

  defp spy_registry do
    registry = Application.fetch_env!(:aiur, :config_semantic_checks)

    spies = %{
      Aiur.Tracker.SemanticCheck.Settings => GitHubSpy,
      Aiur.Claude.Config.SemanticCheck => ClaudeSpy,
      Aiur.Opencode.Config.SemanticCheck => OpencodeSpy
    }

    Application.put_env(:aiur, :config_semantic_checks, Enum.map(registry, fn {group, checks} -> {group, Enum.map(checks, &Map.get(spies, &1, &1))} end))
  end
end

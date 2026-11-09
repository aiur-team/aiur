defmodule Aiur.AgentRunner.PullToolInstallationTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentRunner.{PullToolInstallation, SessionLifecycle, SessionResume}
  alias Aiur.SessionHandle

  setup do
    dir = Aiur.TestSupport.tmp_root!("pull-tool-installed")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{opts: [dir: dir, hostname: "test-host", repo_name: "test-repo"]}
  end

  test "fresh catalog installation survives resume only for its own thread", %{opts: opts} do
    fresh = PullToolInstallation.stamp(%{backend: "codex", resumed: false, thread_id: "new"}, "42", opts)
    assert fresh.pull_tool_installed
    assert :ok = SessionResume.persist_session_handle(fresh, "42", nil, opts)
    assert {:ok, %{pull_tool_installed: true}} = SessionHandle.load("42", "codex", opts)
    assert PullToolInstallation.stamp(%{fresh | resumed: true}, "42", opts).pull_tool_installed
    refute PullToolInstallation.stamp(%{fresh | resumed: true, thread_id: "foreign"}, "42", opts).pull_tool_installed
    SessionLifecycle.report_session_execution(self(), %Aiur.Issue{id: "42"}, fresh)
    assert_received {:session_execution_info, "42", %{pull_tool_installed: true}}
  end

  test "legacy resumed threads and tool-less harnesses fail closed", %{opts: opts} do
    SessionHandle.save("42", %{backend: "codex", thread_id: "old"}, opts)
    refute PullToolInstallation.stamp(%{backend: "codex", resumed: true, thread_id: "old"}, "42", opts).pull_tool_installed
    refute PullToolInstallation.stamp(%{backend: "claude-repl"}, "42", opts).pull_tool_installed

    for backend <- ["claude", "muse", "kimi", "deepseek", "openrouter"] do
      assert PullToolInstallation.stamp(%{backend: backend}, "42", opts).pull_tool_installed
    end
  end
end

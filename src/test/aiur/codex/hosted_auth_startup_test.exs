defmodule Aiur.Codex.HostedAuthStartupTest do
  use Aiur.TestSupport

  alias Aiur.Codex.CodingAgent
  alias Aiur.ProviderAccountGeneration
  alias Aiur.Workflow

  test "unsafe hosted startup auth rejects the session and stops the app server" do
    root = Aiur.TestSupport.tmp_root!("aiur-codex-hosted-auth")
    workspace = Path.join(root, "agent-1")
    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace)
    File.write!(binary, fake_app_server())
    File.chmod!(binary, 0o755)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      workspace_root: root,
      command: "#{binary} app-server"
    )

    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil)
    test_pid = self()

    assert CodingAgent.start_session(workspace,
             instance_mode: "hosted",
             account_generation_server: owner,
             on_provider_started: fn provider ->
               send(test_pid, {:provider_started, provider})
               :ok
             end
           ) == {:error, {:unsafe_hosted_authentication, "codex", :subscription}}

    assert_received {:provider_started, %{root_pid: root_pid}}
    refute process_alive?(root_pid)
  end

  test "unsafe startup notification cannot be replaced by a later API-key account read" do
    root = Aiur.TestSupport.tmp_root!("aiur-codex-hosted-auth-transition")
    workspace = Path.join(root, "agent-1")
    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace)
    File.write!(binary, transitioning_fake_app_server())
    File.chmod!(binary, 0o755)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      workspace_root: root,
      command: "#{binary} app-server"
    )

    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil)

    assert CodingAgent.start_session(workspace,
             instance_mode: "hosted",
             account_generation_server: owner
           ) == {:error, {:unsafe_hosted_authentication, "codex", :subscription}}
  end

  defp fake_app_server do
    """
    #!/usr/bin/env bash
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '%s\n' '{"id":1,"result":{"codexHome":"/tmp/codex"}}' ;;
        *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}' ;;
        *'"id":5'*) printf '%s\n' '{"id":5,"result":{"requiresOpenaiAuth":true,"account":{"type":"chatgpt"}}}'; sleep 600 ;;
      esac
    done
    """
  end

  defp transitioning_fake_app_server do
    """
    #!/usr/bin/env bash
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '%s\n' '{"id":1,"result":{"codexHome":"/tmp/codex"}}' ;;
        *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}' ;;
        *'"id":5'*)
          printf '%s\n' '{"method":"account/updated","params":{"authMode":"chatgpt"}}'
          printf '%s\n' '{"id":5,"result":{"requiresOpenaiAuth":true,"account":{"type":"apiKey"}}}'
          sleep 600
          ;;
      esac
    done
    """
  end

  defp process_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end
end

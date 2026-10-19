defmodule Aiur.Orchestrator.DockerCleanupTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{AgentTeardown, DockerCleanup, State}
  alias Aiur.Workspace.Layout

  setup do
    previous = Application.get_env(:aiur, :docker_cleanup_command)
    on_exit(fn -> restore_env(previous) end)
    owner = self()

    Application.put_env(:aiur, :docker_cleanup_command, fn "docker", args, _opts ->
      send(owner, {:docker, args})

      case args do
        ["ps" | _] -> {"abc123\n", 0}
        _ -> {"", 0}
      end
    end)

    :ok
  end

  test "gracefully stops then removes only containers labelled with the ticket workspace" do
    owner = self()

    command = fn "docker", args, _opts ->
      send(owner, {:docker, args})

      case args do
        ["ps" | _] -> {"abc123\ndef456\n", 0}
        _ -> {"", 0}
      end
    end

    assert :ok = DockerCleanup.cleanup_ticket("AIUR-42", command: command)
    assert_received {:docker, ["ps", "-aq", "--filter", filter]}
    assert filter == "label=aiur.workspace=" <> workspace("AIUR-42")
    assert_received {:docker, ["stop", "-t", "30", "abc123"]}
    assert_received {:docker, ["rm", "abc123"]}
    assert_received {:docker, ["stop", "-t", "30", "def456"]}
    assert_received {:docker, ["rm", "def456"]}
  end

  test "a self-removed --rm container is not a cleanup failure, a real rm error is" do
    rm_result = fn output ->
      fn "docker", args, _opts ->
        case args do
          ["ps" | _] -> {"abc123\n", 0}
          ["stop" | _] -> {"abc123\n", 0}
          ["rm" | _] -> {output, 1}
        end
      end
    end

    for output <- ["Error response from daemon: No such container: abc123", "Error response from daemon: removal of container abc123 is already in progress"] do
      refute capture_log(fn -> DockerCleanup.cleanup_ticket("AIUR-42", command: rm_result.(output)) end) =~ "Could not"
    end

    assert capture_log(fn -> DockerCleanup.cleanup_ticket("AIUR-42", command: rm_result.("permission denied")) end) =~ "Could not stop ticket Docker container"
  end

  test "a hung Docker command is abandoned after the timeout" do
    command = fn "docker", _args, _opts -> Process.sleep(:infinity) end

    assert :ok = DockerCleanup.cleanup_ticket("AIUR-42", command: command, timeout_ms: 10)
  end

  test "terminal cleanup remains best effort when Docker is unavailable" do
    command = fn _executable, _args, _opts -> raise ErlangError, original: :enoent end

    assert :ok = DockerCleanup.cleanup_ticket("AIUR-42", command: command)
  end

  test "terminate and deactivate teardown reap the ticket's containers" do
    teardowns = [
      &AgentTeardown.terminate_running_issue(&1, &2, false),
      &AgentTeardown.terminate_running_issue(&1, &2, true),
      &AgentTeardown.deactivate_running_issue(&1, &2)
    ]

    for teardown <- teardowns do
      teardown.(running_state("AIUR-42"), "issue-42")
      filter = "label=aiur.workspace=" <> workspace("AIUR-42")
      receive_barrier({:docker, ["ps", "-aq", "--filter", ^filter]})
      receive_barrier({:docker, ["stop", "-t", "30", "abc123"]})
      receive_barrier({:docker, ["rm", "abc123"]})
    end
  end

  defp running_state(identifier) do
    issue = %Issue{id: "issue-42", identifier: identifier, state: "in-progress", title: "Docker"}
    entry = %{pid: nil, ref: nil, identifier: identifier, issue: issue, session_id: "session", started_at: DateTime.utc_now(), control: %{status: :working}}
    %State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), max_concurrent_agents: 2, effective_concurrent_agents: 2}
  end

  defp workspace(identifier) do
    {:ok, path} = identifier |> Layout.safe_identifier() |> Layout.workspace_path_for_issue(nil)
    path
  end

  defp restore_env(nil), do: Application.delete_env(:aiur, :docker_cleanup_command)
  defp restore_env(previous), do: Application.put_env(:aiur, :docker_cleanup_command, previous)
end

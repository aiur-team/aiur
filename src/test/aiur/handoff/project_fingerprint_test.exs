defmodule Aiur.Handoff.ProjectFingerprintTest do
  use Aiur.TwoProjectsCase, async: false

  alias Aiur.AgentRunner.Handoff, as: Runner
  alias Aiur.Handoff
  alias Aiur.Handoff.{Adopter, Record}
  alias Aiur.Orchestrator.State
  alias Aiur.TestSupport.WorkflowFiles

  @hello %{"protocol" => 1, "spawn_nonce" => "nonce", "provider_pid" => 123, "relay_id" => "relay", "lossy" => false}

  defp agent(dir, id) do
    issue = %Aiur.Issue{id: id, identifier: id, title: "existing", state: "in-progress"}
    entry = %{identifier: id, session_id: "session-#{id}", issue: issue, started_at: DateTime.add(DateTime.utc_now(), -120), agent_total_tokens: 1, worker_host: nil, turn_count: 1}

    %{
      "issue_id" => id,
      "identifier" => id,
      "workspace" => dir,
      "backend" => "codex",
      "running_entry" => Runner.encode(entry),
      "transport" => Map.merge(@hello, %{"kind" => "relay", "directory" => dir}),
      "dispatch_attempts" => Runner.encode(%{attempts: 1})
    }
  end

  # What `Handoff.prepare/1` writes, built in the project's own context.
  defp write_record(project, agents, extra \\ %{}) do
    in_project(project, fn ->
      record =
        Map.merge(
          %{
            "handoff_schema" => 1,
            "handoff_id" => "restart-#{project.id}",
            "written_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "from_version" => "test",
            "generation" => 1,
            "config_fingerprint" => Handoff.config_fingerprint(),
            "project_id" => Aiur.Project.Context.current_id(),
            "agents" => agents
          },
          extra
        )

      :ok = Record.write(record)
    end)
  end

  defp adopt(project, parent) do
    in_project(project, fn ->
      runner = fn _, _, recipient, _ ->
        send(recipient, {:handoff_adopted, self(), {:ok, %{}}})

        receive do
          :handoff_continue -> :ok
        end

        receive do
          :stop -> :ok
        end
      end

      opts = [
        generation: 2,
        emit_alert: fn name, _ -> send(parent, {:alert, project.id, name}) end,
        relay_probe: fn _ -> {:ok, @hello} end,
        runner: runner,
        stop_agent: fn a -> send(parent, {:stopped, project.id, a["identifier"]}) end,
        issue_state_fetcher: fn ids -> {:ok, Enum.map(ids, &%Aiur.Issue{id: &1, identifier: &1, title: "existing", state: "in-progress"})} end
      ]

      state = Adopter.adopt(%State{max_concurrent_agents: 5}, opts)
      {Map.keys(state.running), Record.path()}
    end)
  end

  defp outcome_reasons(path) do
    {:ok, %{"outcome" => outcomes}} = Aiur.JsonStore.read(path <> ".consumed")
    Map.new(outcomes, &{&1["identifier"], &1["reason"] || &1["status"]})
  end

  test "changing one project's workspace.root falls back only that project's agents on a keep-agents restart", %{a: a, b: b, root: root} do
    dir = Path.join(root, "ws")
    File.mkdir_p!(dir)
    write_record(a, [agent(dir, "a1")])
    write_record(b, [agent(dir, "b1")])

    WorkflowFiles.write_workflow_file!(a.config_path, tracker_kind: "memory", workspace_root: Path.join(root, "moved"))
    assert :ok = in_project(a, fn -> Aiur.WorkflowStore.force_reload(15_000) end)

    assert {[], a_path} = adopt(a, self())
    assert {["b1"], b_path} = adopt(b, self())

    assert Path.dirname(Path.dirname(a_path)) == a.state_root
    assert Path.dirname(Path.dirname(b_path)) == b.state_root
    assert outcome_reasons(a_path) == %{"a1" => ":config_changed"}
    assert outcome_reasons(b_path) == %{"b1" => "adopted"}
    assert_receive {:stopped, "o/a", "a1"}, 1_000
    refute_received {:stopped, "o/b", _}
  end

  test "a record written by another project is never adopted", %{a: a, b: b, root: root} do
    dir = Path.join(root, "ws")
    File.mkdir_p!(dir)
    write_record(a, [agent(dir, "a1")], %{"project_id" => b.id})

    assert {[], path} = adopt(a, self())
    assert outcome_reasons(path) == %{"a1" => ":project_mismatch"}
  end

  test "each project writes its record in its own state root", %{a: a, b: b} do
    paths = for p <- [a, b], do: in_project(p, &Record.path/0)
    assert paths == [Path.join([a.state_root, "handoff", "current.json"]), Path.join([b.state_root, "handoff", "current.json"])]
  end
end

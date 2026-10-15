defmodule Aiur.Orchestrator.AdoptedBootTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.Handoff, as: Runner
  alias Aiur.GitHub.{DispatchAuthorization, Issues}
  alias Aiur.Handoff.{Adopter, Record}
  alias Aiur.Orchestrator.{DispatchPolicy, EnvelopeResume, EnvelopeStore, PressureAdmission, Slots, State}
  alias Aiur.Orchestrator.Dispatcher.Candidates

  setup do
    dir = Aiur.TestSupport.tmp_root!("adopted-boot")
    previous = Application.get_env(:aiur, :envelope_store_path)
    Application.put_env(:aiur, :envelope_store_path, Path.join(dir, "envelope.json"))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :envelope_store_path, previous), else: Application.delete_env(:aiur, :envelope_store_path)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file!(path, max_concurrent_agents: 16, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym")
    File.write!(path, String.replace(File.read!(path), "agent:\n", "agent:\n  target_cpu_pressure: 3\n  target_load_average: 1\n"))
    Aiur.WorkflowStore.force_reload()
    %{dir: dir}
  end

  test "six successful adoptions restore six slots before either pressure path samples", %{dir: dir} do
    state = adopt(dir, 6, 4)
    assert state.effective_concurrent_agents == 6
    assert state.load_envelope_state.bootstrap_complete?
    assert state.load_envelope_state.resume_level == 4
    assert Enum.all?(state.running, fn {_, entry} -> entry.adopted_from == "restart" end)

    for probes <- [
          %{cpu_pressure: %{avg60: 3.0}, pressure_target: 3.0, cpu_snapshot: nil, schedulers: System.schedulers_online()},
          %{cpu_pressure: :unavailable, load: :unavailable, target: 1.0, cpu_snapshot: nil, schedulers: System.schedulers_online()}
        ] do
      assert PressureAdmission.update(state, probes, 120_000, true, false).effective_concurrent_agents == 6
    end

    overloaded = %{cpu_pressure: %{avg60: 9.0}, pressure_target: 3.0, cpu_snapshot: nil, schedulers: System.schedulers_online()}
    backed_off = Enum.reduce(1..3, state, fn i, current -> PressureAdmission.update(current, overloaded, i * 120_000, true, true) end)
    assert backed_off.effective_concurrent_agents == 4
  end

  test "a valid higher record respects new admission caps without losing adopted workers", %{dir: dir} do
    state = adopt(dir, 3, 7)
    assert state.effective_concurrent_agents == 7
    capped = adopt(dir, 3, 9, 5)
    assert capped.effective_concurrent_agents == 5
    occupied = adopt(dir, 6, 4, 5)
    assert occupied.effective_concurrent_agents == 6
    assert Slots.effective_concurrent_agent_limit(occupied) == 5
  end

  test "expired persisted capacity cannot inflate adoption bootstrap", %{dir: dir} do
    assert :ok = EnvelopeStore.save(12, System.schedulers_online(), DateTime.add(DateTime.utc_now(), -86_400))
    state = adopt_record(dir, 3, boot())
    assert state.effective_concurrent_agents == 3
    refute Map.has_key?(state.load_envelope_state, :resume_level)
  end

  # Future regression guard: an empty handoff must preserve #3768 cold admission.
  test "no adopted workers retain the cold start even with a saved level", %{dir: dir} do
    state = adopt(dir, 0, 4)
    assert state.effective_concurrent_agents == 1
    refute state.load_envelope_state.bootstrap_complete?
  end

  test "adopted tickets skip only first-poll authorization while fresh state remains visible", %{dir: dir} do
    old_token = System.get_env("GITHUB_TOKEN")
    key = {Aiur.GitHub.Config, :resolved_token}
    old_cached = :persistent_term.get(key, :unset)
    :persistent_term.erase(key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    DispatchAuthorization.clear_cache()

    on_exit(fn ->
      if old_token, do: System.put_env("GITHUB_TOKEN", old_token), else: System.delete_env("GITHUB_TOKEN")
      if old_cached == :unset, do: :persistent_term.erase(key), else: :persistent_term.put(key, old_cached)
      DispatchAuthorization.clear_cache()
    end)

    state = adopt(dir, 6, 4)
    ids = Enum.map(1..6, &Integer.to_string/1)
    list = Enum.map(ids ++ ["99"], &issue_body/1)

    first_request = fn request ->
      if String.contains?(request.url, "/timeline?") do
        assert request.url =~ "/99/timeline?"
        timeline("99")
      else
        {:ok, %{status: 200, headers: [{"etag", "list-v1"}], body: list}}
      end
    end

    assert {:ok, issues, cache} = Issues.fetch_candidate_issues_conditional(Candidates.candidate_list_cache(state), request_fun: first_request)
    assert Enum.find(issues, &(&1.id == "99")).dispatch_authorized?

    for id <- ids do
      issue = Enum.find(issues, &(&1.id == id))
      assert issue.state == "in-progress"
      refute issue.dispatch_authorized?
      assert match?({:skip, _}, DispatchPolicy.dispatch_decision(issue, state))
    end

    reconciled = Aiur.Orchestrator.Reconciler.refresh_running_issue_states(state, issues, fn _ -> flunk("adopted lifecycle state was already listed") end)
    assert Enum.sort(Map.keys(reconciled.running)) == ids

    later = put_in(state.ci_lifecycle.poll_cache[:candidate_list_cache], cache)
    later = %{later | poll_cycles_completed: 1}
    refute Map.has_key?(Candidates.candidate_list_cache(later), :adopted_issue_ids)

    request = fn request ->
      if String.contains?(request.url, "/timeline?") do
        [_, id] = Regex.run(~r{/issues/(\d+)/timeline}, request.url)
        assert id in ids
        timeline(id)
      else
        assert request.etag == "list-v1"
        {:ok, %{status: 304}}
      end
    end

    assert {:ok, refreshed, _} = Issues.fetch_candidate_issues_conditional(Candidates.candidate_list_cache(later), request_fun: request)
    assert length(refreshed) == 7
    assert Enum.all?(refreshed, & &1.dispatch_authorized?)
  end

  defp boot(cap \\ 16) do
    agent = Aiur.Config.settings!().agent
    %State{max_concurrent_agents: cap, effective_concurrent_agents: DispatchPolicy.initial_load_envelope_limit(agent), load_envelope_state: EnvelopeResume.boot(agent)}
  end

  defp adopt(dir, count, saved, cap \\ 16) do
    assert :ok = EnvelopeStore.save(saved, System.schedulers_online(), DateTime.utc_now())
    adopt_record(dir, count, boot(cap))
  end

  defp adopt_record(dir, count, state) do
    ids = if count == 0, do: [], else: Enum.map(1..count, &Integer.to_string/1)

    agents =
      Enum.map(ids, fn id ->
        issue = %Aiur.Issue{id: id, identifier: id, title: "running", state: "in-progress"}

        %{
          "issue_id" => id,
          "identifier" => id,
          "workspace" => dir,
          "backend" => "codex",
          "config_fingerprint" => "config",
          "running_entry" => Runner.encode(%{issue: issue, identifier: id}),
          "transport" => %{"kind" => "relay", "directory" => dir, "protocol" => 1, "spawn_nonce" => "nonce", "provider_pid" => 123, "relay_id" => "relay"}
        }
      end)

    assert :ok =
             Record.write(
               %{
                 "handoff_schema" => 1,
                 "handoff_id" => "restart",
                 "written_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "from_version" => "test",
                 "generation" => 1,
                 "config_fingerprint" => "config",
                 "agents" => agents
               },
               dir: dir
             )

    parent = self()

    runner = fn _agent, _generation, recipient, _opts ->
      send(recipient, {:handoff_adopted, self(), {:ok, %{}}})
      receive do: (:handoff_continue -> send(parent, {:continued, self()}))
      receive do: (:stop -> :ok)
    end

    next =
      Adopter.adopt(state,
        dir: dir,
        generation: 2,
        config_fingerprint: "config",
        runner: runner,
        relay_probe: fn _ -> {:ok, %{"protocol" => 1, "spawn_nonce" => "nonce", "provider_pid" => 123, "relay_id" => "relay", "lossy" => false}} end
      )

    for _ <- ids do
      assert_receive {:continued, pid}, 1_000
      on_exit(fn -> send(pid, :stop) end)
    end

    next
  end

  defp issue_body(id),
    do: %{"number" => String.to_integer(id), "title" => "fresh", "updated_at" => "2026-10-15T00:00:00Z", "labels" => [%{"name" => "sym:#{if id == "99", do: "todo", else: "in-progress"}"}]}

  defp timeline(id),
    do:
      {:ok,
       %{
         status: 200,
         headers: [],
         body: [
           %{
             "id" => String.to_integer(id),
             "event" => "labeled",
             "created_at" => "2026-10-15T00:00:00Z",
             "label" => %{"name" => "sym:#{if id == "99", do: "todo", else: "in-progress"}"},
             "actor" => %{"login" => "its-everdred"}
           }
         ]
       }}
end

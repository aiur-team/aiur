defmodule Aiur.Experiments.Auto.FeaturePollTest do
  use Aiur.TestSupport
  alias Aiur.Config.Schema.Experiments.Auto, as: Config
  alias Aiur.Events.Exchange
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{Creator, FeatureLine, FeaturePoll, Notifier, WindowRules}
  alias Aiur.Experiments.Store
  alias Aiur.GitHub.ResourceStore

  setup do
    root = Path.join(System.tmp_dir!(), "feature-poll-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, ".aiur/experiments/packs"))
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, Path.join(root, "state"))
    source = %{kind: "event_interval", start: "job.started", end: "job.finished", unit_key: "/id", attrs: %{}}
    metric = %{id: "jobs", label: "Jobs", unit: "ms", unit_of_analysis: "job", kind: "duration", better: "lower", default_direction: "decrease", group: "flow", requires: [], source: source}
    File.write!(Path.join(repo, ".aiur/experiments/packs/app.json"), Jason.encode!(%{schema_version: 1, id: "app", version: "1", metrics: [metric]}))
    config = %Config{metric_packs: ["app"], feature_live_signal: "merge"}
    ctx = %{repo_path: repo, capture_root: Path.join(root, "capture"), clock: ~U[2026-10-10 00:00:00Z]}
    start_supervised!({Store, catalog_context: ctx})
    creator = start_supervised!({Creator, catalog_context: ctx, config: config, telemetry: fn -> true end, path: Path.join(root, "creator.json")})
    parent = self()

    notifier =
      start_supervised!(
        {Notifier,
         path: Path.join(root, "latches.json"),
         publish: fn topic, payload ->
           send(parent, {:published, topic, payload})
           :ok
         end}
      )

    {:ok, upstream} = Agent.start_link(fn -> %{now: ~U[2026-10-10 00:00:00Z], labelled: true, members: [member(1)], merged: false, merge_at: "2026-10-13T00:00:00Z", deny: false} end)

    request = fn req ->
      assert req.caller == "experiments_auto"
      snapshot = Agent.get(upstream, & &1)
      send(parent, {:read, req.url})

      body =
        cond do
          req.method == :post ->
            %{
              "data" => %{
                "repository" => %{
                  "issue" => %{
                    "closedByPullRequestsReferences" => %{
                      "nodes" => if(snapshot.merged, do: [%{"mergedAt" => snapshot.merge_at, "mergeCommit" => %{"oid" => "abc"}}], else: []),
                      "pageInfo" => %{"hasNextPage" => false}
                    }
                  }
                }
              }
            }

          String.contains?(req.url, "sub_issues") ->
            snapshot.members

          true ->
            if(snapshot.labelled, do: [%{"number" => 42}], else: [])
        end

      if snapshot.deny, do: {:error, :budget_denied}, else: {:ok, %{status: 200, body: body, headers: []}}
    end

    opts = [
      path: Path.join(root, "features.json"),
      config: config,
      creator: creator,
      notifier: notifier,
      managed_repo: "owner/repo",
      token: "test-gh-token",
      request_fun: request,
      recent_merges: [],
      clock: fn -> Agent.get(upstream, & &1.now) end
    ]

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{opts: opts, upstream: upstream, root: root}
  end

  defp member(number), do: %{"number" => number, "state" => "open", "state_reason" => nil}

  test "disk reload preserves one arming freeze, refreezes on merge and activates only after quiet", %{opts: opts, upstream: upstream} do
    assert {:ok, data} = FeaturePoll.run(opts, false)
    id = data["epics"]["42"]["state"]["experiment_id"]
    assert is_binary(id)
    assert {:ok, detail} = Experiments.fetch(id)
    assert detail.spec["status"] == "draft"
    refute WindowRules.collecting?(detail.spec)
    assert length(detail.snapshots) == 1
    stop_supervised!(Creator)
    stop_supervised!(Notifier)

    creator =
      start_supervised!(
        {Creator,
         catalog_context: %{repo_path: Path.join(Path.dirname(opts[:path]), "repo")}, config: opts[:config], telemetry: fn -> true end, path: Path.join(Path.dirname(opts[:path]), "creator.json")}
      )

    owner = self()

    notifier =
      start_supervised!(
        {Notifier,
         path: Path.join(Path.dirname(opts[:path]), "latches.json"),
         publish: fn topic, payload ->
           send(owner, {:published, topic, payload})
           :ok
         end}
      )

    opts = opts |> Keyword.put(:creator, creator) |> Keyword.put(:notifier, notifier)
    assert {:ok, _data} = FeaturePoll.run(opts, false)
    assert {:ok, detail} = Experiments.fetch(id)
    assert length(detail.snapshots) == 1
    assert_received {:published, topic, %{experiment_id: ^id}}
    assert String.ends_with?(topic, ".preregister")
    refute_received {:published, ^topic, _payload}
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-13 00:00:00Z], merged: true, members: [%{member(1) | "state" => "closed"}]})
    assert {:ok, _data} = FeaturePoll.run(opts, true)
    assert {:ok, detail} = Experiments.fetch(id)
    assert length(detail.snapshots) == 2
    assert detail.spec["windows"]["before"]["end"] == "2026-10-13T00:00:00Z"
    assert detail.spec["status"] == "draft"
    assert {:ok, _data} = FeaturePoll.run(opts, false)
    assert {:ok, detail} = Experiments.fetch(id)
    assert length(detail.snapshots) == 2
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-13 06:00:00Z]})
    assert {:ok, data} = FeaturePoll.run(opts, false)
    assert data["epics"]["42"]["state"]["phase"] == "line_set"
    assert {:ok, detail} = Experiments.fetch(id)
    assert detail.spec["status"] == "active"
    assert detail.spec["windows"]["after"]["start"] == "2026-10-13T00:00:00Z"
    assert detail.spec["design"]["change"]["evidence"]["excluded"] == %{"start" => "2026-10-13T00:00:00Z", "end" => "2026-10-13T00:00:00Z"}
  end

  test "label removal cancels once and denied discovery leaves persisted state unchanged", %{opts: opts, upstream: upstream} do
    assert {:ok, data} = FeaturePoll.run(opts, false)
    id = data["epics"]["42"]["state"]["experiment_id"]
    original = File.read!(opts[:path])
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-10 01:00:00Z], deny: true})
    assert {:error, _reason} = FeaturePoll.run(opts, false)
    assert File.read!(opts[:path]) == original
    Agent.update(upstream, &%{&1 | labelled: false, deny: false})
    assert {:ok, data} = FeaturePoll.run(opts, false)
    assert data["epics"]["42"]["state"]["phase"] == "cancelled"
    assert {:ok, detail} = Experiments.fetch(id)
    assert detail.spec["status"] == "cancelled"
    assert {:ok, _data} = FeaturePoll.run(opts, false)
    messages = drain([])
    assert Enum.count(messages, &String.ends_with?(&1, ".cancelled")) == 1
    assert Enum.count(messages, &String.ends_with?(&1, ".preregister")) == 1
  end

  test "labelled leaf is visible without creating an experiment", %{opts: opts, upstream: upstream} do
    Agent.update(upstream, &%{&1 | members: []})
    assert {:ok, data} = FeaturePoll.run(opts, false)
    assert data["epics"]["42"]["state"]["phase"] == "not_an_epic"
    assert {:ok, []} = Experiments.list()
  end

  test "a merge refresh inside the throttle is retained until five minutes", %{opts: opts, upstream: upstream} do
    assert {:ok, _data} = FeaturePoll.run(opts, false)
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-10 00:01:00Z], merge_at: "2026-10-10T00:01:00Z", merged: true, members: [%{member(1) | "state" => "closed"}]})
    assert {:ok, deferred} = FeaturePoll.run(opts, true)
    assert deferred["epics"]["42"]["state"]["phase"] == "armed"
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-10 00:05:00Z]})
    assert {:ok, refreshed} = FeaturePoll.run(opts, false)
    assert refreshed["epics"]["42"]["state"]["phase"] == "merging"
    assert refreshed["epics"]["42"]["refresh_requested"] == false
  end

  test "recovered pending live resolution revalidates removal and reopened membership", %{opts: opts, upstream: upstream} do
    assert {:ok, _data} = FeaturePoll.run(opts, false)
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-13 00:00:00Z], merged: true, members: [%{member(1) | "state" => "closed"}]})
    assert {:ok, _data} = FeaturePoll.run(opts, false)
    waiting = opts |> Keyword.put(:config, %{opts[:config] | feature_live_signal: "daemon_boot"}) |> Keyword.put(:deploys, fn _range -> {:error, :offline} end)
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-13 06:00:00Z]})
    assert {:error, :offline} = FeaturePoll.run(waiting, false)
    assert {:ok, pending} = Aiur.JsonStore.read(opts[:path])
    assert pending["epics"]["42"]["pending"] == ["resolve_live"]
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-13 07:00:00Z], members: [member(1)]})
    assert {:ok, reopened} = FeaturePoll.run(opts, false)
    assert reopened["epics"]["42"]["state"]["phase"] == "merging"
    id = reopened["epics"]["42"]["state"]["experiment_id"]
    assert {:ok, detail} = Experiments.fetch(id)
    assert detail.spec["status"] == "draft"
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-13 08:00:00Z], labelled: false})
    assert {:ok, removed} = FeaturePoll.run(opts, false)
    assert removed["epics"]["42"]["state"]["phase"] == "cancelled"
    assert {:ok, detail} = Experiments.fetch(id)
    assert detail.spec["status"] == "cancelled"
  end

  test "supervised worker consumes membership, merge and label deposits without hourly discovery", %{opts: opts, upstream: upstream} do
    worker = start_supervised!({FeatureLine, Keyword.put(opts, :start_paused?, true)})
    worker_poll(worker, fn -> send(worker, :poll) end)
    assert %{epics: %{"42" => %{"phase" => "armed", "experiment_id" => id}}} = FeatureLine.status(worker)
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-10 00:05:00Z], members: [member(1), member(2)]})

    worker_poll(worker, fn ->
      key = ResourceStore.key(:sub_issue, "owner", "repo", "42:2")
      ResourceStore.put_resource(key, %{"present" => true, "parent_issue_number" => 42, "sub_issue_number" => 2}, version: "2026-10-10T00:05:00Z")
    end)

    assert %{epics: %{"42" => %{"member_numbers" => [1, 2]}}} = FeatureLine.status(worker)
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-13 00:00:00Z], merged: true, members: [%{member(1) | "state" => "closed"}, member(2)]})
    worker_poll(worker, fn -> Exchange.publish("ticket.1.pr.merged", %{topic: "ticket.1.pr.merged"}) end)
    assert %{epics: %{"42" => %{"phase" => "merging"}}} = FeatureLine.status(worker)
    worker_poll(worker, fn -> ResourceStore.put_resource(ResourceStore.key(:issue_labels, "owner", "repo", 42), [], version: "2026-10-13T00:01:00Z") end)
    assert %{epics: %{"42" => %{"phase" => "cancelled"}}} = FeatureLine.status(worker)
    assert {:ok, detail} = Experiments.fetch(id)
    assert detail.spec["status"] == "cancelled"
    assert length(detail.snapshots) == 2
  end

  test "worker retries a merge refresh after discovery fails", %{opts: opts, upstream: upstream} do
    worker = start_supervised!({FeatureLine, Keyword.put(opts, :start_paused?, true)})
    worker_poll(worker, fn -> send(worker, :poll) end)
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-10 00:55:00Z]})

    worker_poll(worker, fn ->
      ResourceStore.put_resource(ResourceStore.key(:sub_issue, "owner", "repo", "42:1"), %{"present" => true, "parent_issue_number" => 42, "sub_issue_number" => 1}, version: "2026-10-10T00:55:00Z")
    end)

    Agent.update(upstream, &%{&1 | now: ~U[2026-10-10 01:00:00Z], merge_at: "2026-10-10T01:00:00Z", deny: true, merged: true, members: [%{member(1) | "state" => "closed"}]})
    worker_poll(worker, fn -> Exchange.publish("ticket.1.pr.merged", %{topic: "ticket.1.pr.merged"}) end, :unavailable)
    Agent.update(upstream, &%{&1 | now: ~U[2026-10-10 01:01:00Z], deny: false})
    worker_poll(worker, fn -> send(worker, :poll) end)
    assert %{epics: %{"42" => %{"phase" => "merging"}}} = FeatureLine.status(worker)
    assert {:ok, [_one_experiment]} = Experiments.list()
  end

  test "disabled capture skips a feature once without an experiment or notification", %{opts: opts, root: root} do
    stop_supervised!(Creator)
    creator = start_supervised!({Creator, path: Path.join(root, "creator.json"), telemetry: fn -> false end})
    opts = Keyword.put(opts, :creator, creator)

    log =
      capture_log(fn ->
        assert {:ok, data} = FeaturePoll.run(opts, false)
        assert data["epics"]["42"]["state"]["phase"] == "skipped"
        refute data["epics"]["42"]["state"]["experiment_id"]
        assert {:ok, again} = FeaturePoll.run(opts, false)
        assert again["epics"]["42"]["state"]["phase"] == "skipped"
      end)

    assert length(Regex.scan(~r/automatic experiment skipped: telemetry disabled/, log)) == 1
    assert {:ok, []} = Experiments.list()
    refute_received {:published, _topic, _payload}
  end

  defp worker_poll(worker, trigger, expected \\ :available) do
    owner = self()
    token = make_ref()

    hook = fn state, event, _process_state ->
      case {state, event} do
        {_, {:noreply, %{task: task}}} when not is_nil(task) ->
          :running

        {:running, {:noreply, %{task: nil}}} ->
          send(owner, {:worker_finished, token})
          :done

        _other ->
          state
      end
    end

    :ok = :sys.install(worker, {hook, :waiting})
    trigger.()
    receive_barrier({:worker_finished, ^token})
    :ok = :sys.remove(worker, hook)
    assert %{status: ^expected} = FeatureLine.status(worker)
  end

  defp drain(acc) do
    receive do
      {:published, topic, _payload} -> drain([topic | acc])
    after
      0 -> acc
    end
  end
end

defmodule Aiur.Experiments.Auto.FeaturePollTest do
  use Aiur.TestSupport
  alias Aiur.Config.Schema.Experiments.Auto, as: Config
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{Creator, FeaturePoll, Notifier, WindowRules}
  alias Aiur.Experiments.Store

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

    {:ok, upstream} = Agent.start_link(fn -> %{now: ~U[2026-10-10 00:00:00Z], labelled: true, members: [member(1)], merged: false, deny: false} end)

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
                      "nodes" => if(snapshot.merged, do: [%{"mergedAt" => "2026-10-13T00:00:00Z", "mergeCommit" => %{"oid" => "abc"}}], else: []),
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
    creator = start_supervised!({Creator, catalog_context: %{repo_path: Path.join(Path.dirname(opts[:path]), "repo")}, config: opts[:config], telemetry: fn -> true end, path: Path.join(Path.dirname(opts[:path]), "creator.json")})
    owner = self()
    notifier = start_supervised!({Notifier, path: Path.join(Path.dirname(opts[:path]), "latches.json"), publish: fn topic, payload -> send(owner, {:published, topic, payload}); :ok end})
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

  defp drain(acc) do
    receive do
      {:published, topic, _payload} -> drain([topic | acc])
    after
      0 -> acc
    end
  end
end

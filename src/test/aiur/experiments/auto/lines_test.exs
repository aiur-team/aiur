defmodule Aiur.Experiments.Auto.LinesTest do
  use Aiur.TestSupport
  alias Aiur.Config.Schema.Experiments.Auto, as: AutoConfig
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{AiurVersionLine, Creator, DeployLedger, Line, RepoReleaseLine}
  alias Aiur.Experiments.Store

  setup do
    root = Path.join(System.tmp_dir!(), "auto-lines-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, ".aiur/experiments/packs"))
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, Path.join(root, "state"))

    metric = %{
      id: "count",
      label: "Count",
      unit: "events",
      unit_of_analysis: "job",
      kind: "count",
      better: "higher",
      default_direction: "increase",
      group: "flow",
      requires: [],
      source: %{kind: "event_count", match: "job.finished", unit_key: "/id"}
    }

    pack = %{schema_version: 1, id: "app", version: "1", metrics: [metric]}
    File.write!(Path.join(repo, ".aiur/experiments/packs/app.json"), Jason.encode!(pack))
    ctx = %{repo_path: repo, capture_root: Path.join(root, "capture"), clock: ~U[2026-10-10 00:00:00Z]}
    start_supervised!({Store, catalog_context: ctx})
    config = %AutoConfig{metric_packs: ["app"]}
    creator_opts = [catalog_context: ctx, config: config, telemetry: fn -> true end, path: Path.join(root, "creator.json")]
    creator = start_supervised!({Creator, creator_opts})
    ledger = [path: Path.join(root, "deploys.ndjson"), release_dir: nil, instance_id: nil]
    release = [path: Path.join(root, "seen.json"), repo: repo, config: config, creator: creator, now: ~U[2026-10-10 00:00:00Z]]

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root, repo: repo, pack: pack, creator: creator, creator_opts: creator_opts, ledger: ledger, release: release}
  end

  defp boot(ctx, version, at, id) do
    ledger = Keyword.merge(ctx.ledger, aiur_version: version, at: at, boot_id: id)
    assert {:ok, _row} = DeployLedger.record_boot(ledger)
    AiurVersionLine.evaluate(ledger_opts: ledger, creator: ctx.creator)
  end

  defp release(ctx, tags, dates) do
    RepoReleaseLine.poll(ctx.release ++ [list: fn _repo -> {:ok, tags} end, date: fn _repo, tag -> {:ok, Map.fetch!(dates, tag)} end])
  end

  defp line(source, ref, at) do
    prefix = if source == :aiur_version, do: "version", else: "release"
    %Line{source: source, key: "auto:#{prefix}:#{ref}", at: at}
  end

  test "first boot, five restarts, nightly variants and unknown versions are silent", ctx do
    for {version, index} <- Enum.with_index(List.duplicate("0.0.9", 5) ++ ["0.0.9-nightly.a", "0.0.9-nightly.b", "0.0.9", "unknown", "0.0.10"]) do
      assert :ok = boot(ctx, version, DateTime.add(~U[2026-10-01 00:00:00Z], index * 60), "boot-#{index}")
    end

    assert {:ok, []} = Experiments.list()
    assert {:ok, rows} = DeployLedger.list({~U[2026-10-01 00:00:00Z], ~U[2026-10-02 00:00:00Z]}, ctx.ledger)
    assert length(rows) == 10
  end

  test "upgrade freezes baseline in that boot and clips it to the previous version change", ctx do
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-01 00:00:00Z], "old")
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-03 00:00:00Z], "restart")
    assert {:ok, spec} = boot(ctx, "0.0.10-nightly.a", ~U[2026-10-10 00:00:00Z], "upgrade")
    assert spec.key == "auto:version:0.0.10"
    assert spec.design["change"]["time"] == "2026-10-10T00:00:00Z"
    assert spec.windows["before"]["start"] == "2026-10-01T00:00:00Z"
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(spec.id)
    assert snapshot["window"] == spec.windows["before"]
    assert :ok = boot(ctx, "0.0.10-nightly.b", ~U[2026-10-10 01:00:00Z], "nightly")
    assert :ok = boot(ctx, "0.0.10", ~U[2026-10-10 02:00:00Z], "stable")
    assert {:ok, [%{id: id}]} = Experiments.list()
    assert id == spec.id
  end

  test "failed upgrade creation survives another same-version boot with its original line time", ctx do
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-01 00:00:00Z], "old")
    stop_supervised!(Creator)
    bad = start_supervised!({Creator, Keyword.put(ctx.creator_opts, :config, %AutoConfig{metric_packs: ["missing"]})})
    assert {:error, {:metric_packs_unavailable, ["missing"]}} = boot(%{ctx | creator: bad}, "0.0.10", ~U[2026-10-09 00:00:00Z], "failed-upgrade")
    stop_supervised!(Creator)
    creator = start_supervised!({Creator, ctx.creator_opts})
    assert {:ok, spec} = boot(%{ctx | creator: creator}, "0.0.10", ~U[2026-10-10 00:00:00Z], "retry-boot")
    assert spec.design["change"]["time"] == "2026-10-09T00:00:00Z"
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(spec.id)
    assert snapshot["window"]["end"] == "2026-10-09T00:00:00Z"
    assert :ok = boot(%{ctx | creator: creator}, "0.0.10", ~U[2026-10-10 01:00:00Z], "done")
    assert {:ok, %{snapshots: [_only]}} = Experiments.fetch(spec.id)
  end

  test "telemetry-skipped upgrade stays skipped after telemetry is enabled on another boot", ctx do
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-01 00:00:00Z], "old")
    stop_supervised!(Creator)
    disabled = start_supervised!({Creator, Keyword.put(ctx.creator_opts, :telemetry, fn -> false end)})
    assert {:ok, :skipped} = boot(%{ctx | creator: disabled}, "0.0.10", ~U[2026-10-09 00:00:00Z], "disabled")
    stop_supervised!(Creator)
    enabled = start_supervised!({Creator, ctx.creator_opts})
    assert {:ok, :skipped} = boot(%{ctx | creator: enabled}, "0.0.10", ~U[2026-10-10 00:00:00Z], "enabled")
    assert {:ok, []} = Experiments.list()
  end

  test "rollback truncates and annotates the open experiment without a new experiment", ctx do
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-01 00:00:00Z], "old")
    assert {:ok, spec} = boot(ctx, "0.0.10", ~U[2026-10-08 00:00:00Z], "new")
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-09 00:00:00Z], "rollback")
    assert {:ok, detail} = Experiments.fetch(spec.id)
    assert detail.spec["windows"]["after"]["end"] == "2026-10-09T00:00:00Z"
    assert [%{"reason" => "rollback to 0.0.9"}] = detail.annotations
    assert length(detail.snapshots) == 1
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-10 00:00:00Z], "after-rollback")
    assert {:ok, %{annotations: [_only]}} = Experiments.fetch(spec.id)
    assert {:ok, [_only]} = Experiments.list()
  end

  for {first, second} <- [{:aiur_version, :repo_release}, {:repo_release, :aiur_version}] do
    test "version and release dedupe with #{first} first across Creator restart", ctx do
      first = unquote(first)
      second = unquote(second)
      ref = fn source -> if source == :aiur_version, do: "0.0.10", else: "v0.0.10" end
      assert {:ok, spec} = Creator.create(line(first, ref.(first), ~U[2026-10-09 00:00:00Z]), ctx.creator)
      stop_supervised!(Creator)
      creator = start_supervised!({Creator, ctx.creator_opts})
      next = line(second, ref.(second), ~U[2026-10-10 00:00:00Z])
      assert {:ok, %{id: id}} = Creator.create(next, creator)
      assert id == spec.id
      assert {:ok, :exists} = Creator.create(next, creator)
      assert {:ok, [_only]} = Experiments.list()
      assert {:ok, detail} = Experiments.fetch(id)
      assert detail.spec["design"]["change"]["evidence"]["source"] == to_string(first)
      assert [%{"source" => source, "auto_line_key" => key}] = detail.annotations
      assert source == to_string(second)
      assert key == next.key
      assert length(detail.snapshots) == 1
    end
  end

  test "version boot matching an interval-grouped tag reuses its experiment", ctx do
    assert {:ok, spec} = Creator.create(line(:repo_release, "v2.3.0", ~U[2026-10-06 00:00:00Z]), ctx.creator)
    assert {:ok, %{id: id}} = Creator.create(line(:repo_release, "v2.3.1", ~U[2026-10-09 00:00:00Z]), ctx.creator)
    assert id == spec.id
    assert {:ok, %{id: ^id}} = Creator.create(line(:aiur_version, "2.3.1", ~U[2026-10-10 00:00:00Z]), ctx.creator)
    assert {:ok, [_only]} = Experiments.list()
    assert {:ok, detail} = Experiments.fetch(id)
    assert Enum.map(detail.annotations, & &1["auto_line_key"]) == ["auto:release:v2.3.1", "auto:version:2.3.1"]
  end

  test "same semver outside fourteen days creates a second experiment", ctx do
    assert {:ok, _spec} = Creator.create(line(:aiur_version, "0.0.10", ~U[2026-09-20 00:00:00Z]), ctx.creator)
    assert {:ok, _spec} = Creator.create(line(:repo_release, "v0.0.10", ~U[2026-10-10 00:00:00Z]), ctx.creator)
    assert {:ok, rows} = Experiments.list()
    assert length(rows) == 2
  end

  test "first tag census is silent; subsequent tags use source date and interval annotation", ctx do
    assert :ok = release(ctx, ["v2.2.0"], %{})
    assert {:ok, []} = Experiments.list()
    dates = %{"v2.3.0" => ~U[2026-10-06 00:00:00Z], "v2.3.1" => ~U[2026-10-09 00:00:00Z]}
    assert :ok = release(ctx, ["v2.2.0", "v2.3.1", "v2.3.0"], dates)
    assert {:ok, [%{id: id}]} = Experiments.list()
    assert {:ok, detail} = Experiments.fetch(id)
    assert detail.spec["key"] == "auto:release:v2.3.0"
    assert detail.spec["design"]["change"]["time"] == "2026-10-06T00:00:00Z"
    assert [%{"auto_line_key" => "auto:release:v2.3.1"}] = detail.annotations
    assert :ok = release(ctx, ["v2.2.0", "v2.3.1", "v2.3.0"], %{})
    assert {:ok, %{annotations: [_only]}} = Experiments.fetch(id)
  end

  test "old, prerelease, nonmatching and nonsemver tags are marked seen without experiments", ctx do
    assert :ok = release(ctx, [], %{})
    tags = ["v1.0.0", "v1.0.1-rc.1", "release-2026", "vgarbage"]
    assert :ok = release(ctx, tags, %{"v1.0.0" => ~U[2026-09-01 00:00:00Z]})
    assert {:ok, []} = Experiments.list()
    assert Jason.decode!(File.read!(ctx.release[:path])) == tags
  end

  test "offline and date failures preserve seen state and next tick retries", ctx do
    path = ctx.release[:path]
    offline = Keyword.put(ctx.release, :list, fn _repo -> {:error, :offline} end)
    assert {:error, :offline} = RepoReleaseLine.poll(offline)
    refute File.exists?(path)
    assert :ok = release(ctx, [], %{})
    before = File.read!(path)
    assert {:error, :offline} = RepoReleaseLine.poll(offline)
    assert File.read!(path) == before
    opts = ctx.release ++ [list: fn _repo -> {:ok, ["v1.0.0"]} end, date: fn _repo, _tag -> {:error, :offline} end]
    assert {:error, :offline} = RepoReleaseLine.poll(opts)
    assert File.read!(path) == before
    assert :ok = release(ctx, ["v1.0.0"], %{"v1.0.0" => ~U[2026-10-10 00:00:00Z]})
    assert {:ok, [_only]} = Experiments.list()
  end

  test "missing warm clone reports unavailable without creating a seen file", ctx do
    opts = ctx.release |> Keyword.put(:repo, Path.join(ctx.root, "missing")) |> Keyword.put(:name, nil)
    source = start_supervised!({RepoReleaseLine, opts})
    assert :ok = wait_status(source, :unavailable)
    refute File.exists?(ctx.release[:path])
  end

  test "boot supervisor runs version source after ledger and creator", ctx do
    stop_supervised!(Creator)
    assert :ok = boot(ctx, "0.0.9", ~U[2026-10-01 00:00:00Z], "old")
    ledger = Keyword.merge(ctx.ledger, aiur_version: "0.0.10", at: ~U[2026-10-10 00:00:00Z], boot_id: "new", name: nil)
    config = %AutoConfig{metric_packs: ["app"], release_line: false}
    supervisor = start_supervised!({Aiur.Experiments.Auto, name: nil, config: config, ledger_opts: ledger, creator_opts: ctx.creator_opts, version_opts: [name: nil]})
    # The call is ordered behind the source's boot continuation.
    [{_id, source, _type, _modules}] = Supervisor.which_children(supervisor) |> Enum.filter(fn {id, _, _, _} -> id == AiurVersionLine end)
    :sys.get_state(source)
    assert {:ok, [%{id: id}]} = Experiments.list()
    assert {:ok, %{snapshots: [snapshot]}} = Experiments.fetch(id)
    assert snapshot["window"]["end"] == "2026-10-10T00:00:00Z"
  end

  test "prerelease opt-in and consumer auto packs participate in release creation", ctx do
    pack = ctx.pack |> Map.put(:id, "consumer") |> Map.put(:auto, true)
    File.write!(Path.join(ctx.repo, ".aiur/experiments/packs/consumer.json"), Jason.encode!(pack))
    ctx = %{ctx | release: Keyword.put(ctx.release, :config, %AutoConfig{metric_packs: ["app"], release_include_prereleases: true})}
    # Creator owns metric selection, using the same runtime configuration as the source.
    stop_supervised!(Creator)
    creator = start_supervised!({Creator, Keyword.put(ctx.creator_opts, :config, ctx.release[:config])})
    ctx = %{ctx | release: Keyword.put(ctx.release, :creator, creator)}
    assert :ok = release(ctx, [], %{})
    assert :ok = release(ctx, ["v1.0.0-rc.1"], %{"v1.0.0-rc.1" => ~U[2026-10-10 00:00:00Z]})
    assert {:ok, [%{id: id}]} = Experiments.list()
    assert {:ok, detail} = Experiments.fetch(id)
    assert Enum.map(detail.spec["metrics"], & &1["ref"]) == ["app/count", "consumer/count"]
    assert Map.keys(hd(detail.snapshots)["metrics"]) |> Enum.sort() == ["app/count", "consumer/count"]
  end

  test "status remains responsive and overlapping polls are coalesced", ctx do
    caller = self()

    list = fn _repo ->
      send(caller, {:poll_started, self()})

      receive do
        :finish -> {:ok, []}
      end
    end

    source = start_supervised!({RepoReleaseLine, ctx.release ++ [name: nil, list: list]})
    assert_receive {:poll_started, task}, 1_000
    assert %{status: :pending} = RepoReleaseLine.status(source)
    send(source, :poll)
    assert %{status: :pending} = RepoReleaseLine.status(source)
    refute_received {:poll_started, _task}
    send(task, :finish)
    assert :ok = wait_status(source, :available)
    assert Jason.decode!(File.read!(ctx.release[:path])) == []
  end

  test "unchanged tag polls do not rewrite state, including deleted tags", ctx do
    assert :ok = release(ctx, ["v1.0.0"], %{})
    path = ctx.release[:path]
    assert :ok = File.touch(path, {{2020, 1, 1}, {0, 0, 0}})
    assert :ok = release(ctx, [], %{})
    assert :ok = release(ctx, ["v1.0.0"], %{})
    assert {:ok, %{mtime: {{2020, 1, 1}, {0, 0, 0}}}} = File.stat(path)
    assert Jason.decode!(File.read!(path)) == ["v1.0.0"]
    assert {:ok, []} = Experiments.list()
  end

  defp wait_status(source, expected) do
    owner = self()
    token = make_ref()

    hook = fn state, event, _proc_state ->
      case event do
        {:noreply, %{status: ^expected}} ->
          send(owner, {:poll_finished, token})
          :done

        _other ->
          state
      end
    end

    :ok = :sys.install(source, {hook, :armed})
    if :sys.get_state(source).status == expected, do: send(owner, {:poll_finished, token})
    receive_barrier({:poll_finished, ^token})
    :ok = :sys.remove(source, hook)
    assert %{status: ^expected} = RepoReleaseLine.status(source)
    :ok
  end
end

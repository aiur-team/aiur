defmodule Aiur.FeatureCLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.BuildOrder.Features
  alias Aiur.FeatureCLI
  alias Aiur.FeatureCLI.Output

  @now ~U[2026-10-08 10:00:00Z]
  setup do
    dir = Aiur.TestSupport.tmp_root!("feature-cli")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, store_clock} = Agent.start_link(fn -> @now end)
    {:ok, pid} = Features.start_link(name: nil, state_dir: dir, clock: fn -> Agent.get(store_clock, & &1) end, general_epics: fn -> {:ok, []} end)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    context = [
      server: pid,
      actor: "cli:tester",
      source: "cli:tester",
      clock: fn -> DateTime.add(@now, 259_200) end,
      label_states: fn _ -> {:ok, %{}} end,
      label_status: fn -> {:error, :registry_unavailable} end
    ]

    %{context: context, pid: pid, store_clock: store_clock}
  end

  test "create reruns ignore auto hue but refuse different values", %{context: context, pid: pid} do
    assert {:ok, %{outcome: :created}} = op(:create, context, label: "A")
    assert {:ok, %{outcome: :unchanged}} = op(:create, context, label: "A")
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    other_hue = rem(snapshot.features["a"].hue + 1, 360)
    assert {:error, {:feature_exists, "a"}} = op(:create, context, label: "A", hue: other_hue)
    assert {:ok, journal} = Features.journal("a", server: pid)
    assert length(journal) == 1
  end

  test "add reruns and conflicts preserve atomic membership and report moved owner", %{context: context, pid: pid} do
    create(context)
    assert {:ok, %{results: [%{outcome: :added, label: "unknown"}]}} = op(:add, context, ids: [12])
    assert {:ok, %{results: [%{outcome: :unchanged}]}} = op(:add, context, ids: [12])
    assert {:ok, _} = FeatureCLI.apply_op(%{op: :create, slug: "b", label: "B"}, context)
    assert {:error, {:owned_elsewhere, [{12, "a"}]}} = FeatureCLI.apply_op(%{op: :add, slug: "b", ids: [11, 12]}, context)
    assert :none = Features.owner(11, server: pid)
    assert {:ok, %{results: [%{outcome: :moved, previous_feature: "a"}]}} = FeatureCLI.apply_op(%{op: :add, slug: "b", ids: [12], move: true}, context)
  end

  test "remove prefilters nonmembers and retries without new events", %{context: context, pid: pid} do
    create(context)
    op(:add, context, ids: [12])
    assert {:ok, %{results: [%{id: 12, outcome: :removed} = removed, %{id: 13, outcome: :unchanged}]}} = op(:remove, context, ids: [12, 13])
    refute Map.has_key?(removed, :label)
    assert {:ok, first} = Features.journal("a", server: pid)
    assert {:ok, %{results: [%{outcome: :unchanged}, %{outcome: :unchanged}]}} = op(:remove, context, ids: [12, 13])
    assert {:ok, ^first} = Features.journal("a", server: pid)
  end

  test "also refuses owners and links are idempotent", %{context: context} do
    create(context)
    op(:add, context, ids: [12])
    assert {:error, {:owner_cannot_also, [12]}} = op(:also, context, ids: [12])
    assert {:ok, %{results: [%{outcome: :added}]}} = op(:also, context, ids: [13])
    assert {:ok, %{results: [%{outcome: :unchanged}]}} = op(:also, context, ids: [13])
    assert {:ok, %{also: [13]}} = op(:show, context)
    assert {:ok, %{results: [%{outcome: :removed}]}} = op(:also, context, ids: [13], remove: true)
  end

  test "backfill records source and unconfirmed membership", %{context: context, pid: pid} do
    create(context)
    opts = context ++ [op: :add, slug: "a", ids: [12], who: "tester", source: "backfill-agent", json: true]
    json = capture_io(fn -> assert FeatureCLI.run(opts) == 0 end)
    assert [%{"confirmed" => false, "actor" => "cli:tester", "source" => "backfill-agent"}] = Jason.decode!(json)["results"]
    assert {:ok, %{confirmed: false, source: "backfill-agent"}} = Features.owner(12, server: pid)
    assert {:ok, %{results: [%{confirmed: true, outcome: :updated}]}} = op(:add, context, ids: [12])
  end

  test "baseline refusal and replacement show age and previous scope", %{context: context, pid: pid, store_clock: store_clock} do
    create(context)
    op(:add, context, ids: [12, 13])
    assert {:ok, _} = op(:baseline, context)
    assert {:error, {:baseline_exists, %{age_ms: 259_200_000, members: [12, 13]}}} = op(:baseline, context)
    assert {:ok, %{feature: %{baseline: baseline}} = shown} = op(:show, context)
    assert baseline.age_ms == 259_200_000
    assert Output.render(shown) =~ "baseline set 3d ago"
    replacement_at = DateTime.add(@now, 60)
    Agent.update(store_clock, fn _ -> replacement_at end)
    assert {:ok, replacement} = op(:baseline, context, replace: true)
    assert Output.render(replacement) =~ "replaced baseline set 3d ago with 2 members (2026-10-08T10:00:00Z)"
    assert {:ok, %{features: %{"a" => %{baseline: %{at: ^replacement_at}}}}} = Features.snapshot(server: pid)
  end

  test "show preserves null unknown labels and renders membership provenance", %{context: context} do
    create(context)
    op(:add, context, ids: [12, 13])
    assert {:ok, shown} = op(:show, context)
    assert shown.feature.baseline == nil
    assert shown.labels == nil
    assert Enum.map(shown.members, & &1.label) == ["unknown", "unknown"]
    assert Map.keys(shown.feature) |> Enum.sort() == Enum.sort([:key, :label, :hue, :epics, :from, :to, :baseline, :public_ref])
    text = Output.render(shown)
    assert text =~ "no baseline: all 2 members count as original"
    assert text =~ "label status unknown"
    assert text =~ "confirmed true label unknown"
    assert text =~ "cli:tester by cli:tester"
    ctx = Keyword.put(context, :label_states, fn _ -> {:ok, %{12 => :exempt, 13 => :held_backfill}} end)
    assert {:ok, %{members: [%{label: "exempt"}, %{label: "held"}]}} = op(:show, ctx)
  end

  test "a valid unknown ending remains unknown in list and detail", %{context: context, pid: pid} do
    create(context)
    assert {:ok, _} = Features.update_feature("a", %{to: :unknown}, server: pid, source: "import:test", actor: "cli:tester")
    assert {:ok, shown} = op(:show, context)
    assert shown.feature.to == :unknown
    assert Output.render(shown) =~ "end unknown"
    refute Output.render(shown) =~ "ended"
    assert {:ok, listed} = FeatureCLI.apply_op(%{op: :show}, context)
    assert Output.render(listed) =~ "end unknown"
  end

  test "edit updates registry label end and epics", %{context: context, pid: pid} do
    create(context)
    assert {:ok, _} = op(:edit, context, label: "New", end: "now", add_epics: [%{key: "extra", label: "Extra"}])
    assert {:ok, %{features: %{"a" => feature}}} = Features.snapshot(server: pid)
    assert feature.label == "New"
    assert feature.to == DateTime.add(@now, 259_200)
    assert List.last(feature.epics) == %{key: "extra", label: "Extra"}
    assert {:ok, listed} = FeatureCLI.apply_op(%{op: :show}, context)
    assert Output.render(listed) =~ "ended"
  end

  test "unavailable registry is an error in human and JSON output" do
    opts = [op: :show, server: :missing_feature_cli_test, error_fun: fn message -> send(self(), {:error_text, message}) end]
    text = capture_io(fn -> assert FeatureCLI.run(opts) == 1 end)
    refute text =~ "no features"
    assert_receive {:error_text, message}, 1_000
    assert message =~ "feature registry unavailable"
    json = capture_io(fn -> assert FeatureCLI.run(Keyword.put(opts, :json, true)) == 1 end)
    assert Jason.decode!(json)["ok"] == false
  end

  test "validation rejects bounds and CLI provenance cannot claim agent identity", %{context: context} do
    assert {:usage, _} = op(:add, context, ids: [2_147_483_648])
    assert {:usage, _} = op(:add, context, ids: Enum.to_list(1..201))
    assert {:usage, _} = op(:edit, context)
    assert {:usage, _} = op(:create, context, label: "A", hue: 400)
    assert {:usage, _} = op(:add, context, ids: [1], source: "agent:77")
    capture_io(fn -> assert FeatureCLI.run(op: :create, slug: "a", label: "A", who: "agent:77", error_fun: fn _ -> :ok end) == 64 end)
  end

  defp create(context), do: op(:create, context, label: "A")
  defp op(op, context, opts \\ []), do: FeatureCLI.apply_op(Map.merge(%{op: op, slug: "a"}, Map.new(opts)), context)
end

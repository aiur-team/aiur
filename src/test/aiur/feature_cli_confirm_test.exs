defmodule Aiur.FeatureCLIConfirmTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.BuildOrder.Features
  alias Aiur.FeatureCLI

  @now ~U[2026-10-08 10:00:00Z]
  setup do
    dir = Aiur.TestSupport.tmp_root!("feature-cli-confirm")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    pid = start_supervised!({Features, name: nil, state_dir: dir, clock: fn -> @now end, general_epics: fn -> {:ok, []} end})
    meta = [server: pid, source: "cli:tester", actor: "cli:tester"]
    for slug <- ["a", "b"], do: Features.create(slug, %{label: String.upcase(slug)}, meta)
    {:ok, _} = Features.add("a", [12], Keyword.put(meta, :source, "backfill-agent"))
    {:ok, _} = Features.add("b", [20], Keyword.put(meta, :source, "backfill-agent"))
    {:ok, _} = Features.add("a", [13], meta)
    context = [server: pid, who: "kevin", clock: fn -> @now end, label_states: fn _ -> {:ok, %{}} end, label_status: fn -> {:error, :not_running} end]
    %{context: context, meta: meta}
  end

  test "unconfirmed show lists owners across features and within one feature", %{context: context} do
    opts = context ++ [op: :show, unconfirmed: true]
    text = run(opts)
    assert text =~ "#12  a  f-a  backfill-agent"
    assert text =~ "#20  b  f-b  backfill-agent"
    refute text =~ "#13"
    assert text =~ "2 unconfirmed\n"
    json = run(opts ++ [json: true]) |> Jason.decode!()
    assert json["unconfirmed_count"] == 2
    assert Enum.map(json["members"], &{&1["id"], &1["confirmed"]}) == [{12, false}, {20, false}]
    assert run(opts ++ [slug: "a"]) =~ "1 unconfirmed\n"
    refute run(opts ++ [slug: "a"]) =~ "#20"
  end

  test "confirm reports atomic previous value without label reads and is idempotent", %{context: context, meta: meta} do
    opts = Keyword.put(context, :label_states, fn _ -> flunk("confirm must not read labels") end) ++ [op: :confirm, slug: "a", ids: [12, 13], json: true]
    json = run(opts) |> Jason.decode!()
    assert json["command"] == "feature confirm"
    assert [%{"id" => 12, "outcome" => "confirmed", "epic" => "f-a", "previous" => %{"source" => "backfill-agent", "confirmed" => false}}, %{"id" => 13, "outcome" => "unchanged"}] = json["results"]
    assert {:ok, %{confirmed: true, source: "cli:kevin"}} = Features.owner(12, meta)
    assert run(Keyword.delete(opts, :json)) =~ "unchanged (already confirmed)"
    assert run(context ++ [op: :show, slug: "a", unconfirmed: true]) =~ "\n0 unconfirmed\n"
  end

  @tag :future_regression
  test "future regression guard: unavailable show returns failure without inventing a count" do
    opts = [server: :missing_feature_confirm, op: :show, unconfirmed: true, error_fun: &IO.puts/1]
    text = capture_io(fn -> assert FeatureCLI.run(opts) == 1 end)
    assert text =~ "feature registry unavailable"
    refute text =~ ~r/^\d+ unconfirmed$/m
    json = capture_io(fn -> assert FeatureCLI.run(Keyword.merge(opts, json: true, error_fun: fn _ -> :ok end)) == 1 end) |> Jason.decode!()
    assert json["ok"] == false
    refute Map.has_key?(json, "unconfirmed_count")
  end

  test "confirm rejects an invalid member without accepting valid rows", %{context: context, meta: meta} do
    opts = context ++ [op: :confirm, slug: "a", ids: [12, 20], json: true, error_fun: fn _ -> :ok end]
    json = capture_io(fn -> assert FeatureCLI.run(opts) == 1 end) |> Jason.decode!()
    assert json["ok"] == false
    assert json["refused"] == [%{"id" => 20, "reason" => "not_member"}]
    assert {:ok, %{confirmed: false}} = Features.owner(12, meta)
  end

  defp run(opts), do: capture_io(fn -> assert FeatureCLI.run(opts) == 0 end)
end

defmodule AiurWeb.OperatorControlCenter.Analytics.LatestRunTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Summaries
  alias AiurWeb.OperatorControlCenter.Analytics.LatestRun

  @summary_fixture Path.expand("../../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)

  defp decoded_summary! do
    {:ok, dataset} = @summary_fixture |> File.read!() |> Summaries.decode_summary()
    dataset
  end

  defp summary_with_end(dataset, end_iso) do
    put_in(dataset, [:provenance, :time_range, :end], end_iso)
  end

  defp ticket_analyzable?(dataset), do: Map.get(dataset, :tickets, %{}) |> map_size() > 0

  test "returns the live boot when it is analyzable" do
    file = write_live_file!([route_record("live-boot", 1, "dispatch", ~U[2026-07-12 00:01:00Z], "7")])

    assert {:ok, dataset} = LatestRun.load(file, "live-boot", &ticket_analyzable?/1)
    assert Map.has_key?(dataset.tickets, "7")
  end

  test "returns the live boot even when a retained prior summary exists" do
    file = write_live_file!([route_record("new-boot", 1, "dispatch", ~U[2026-07-12 00:01:00Z], "7")])
    prior = decoded_summary!()

    opts = [cache_identity: make_ref(), prior_loader: fn -> {[prior], false} end]

    assert {:ok, dataset} = LatestRun.load(file, "new-boot", &ticket_analyzable?/1, opts)
    assert Map.has_key?(dataset.tickets, "7")
  end

  test "falls back to the newest analyzable retained summary after a restart" do
    file = write_live_file!([route_record("new-boot", 1, "restart", ~U[2026-07-12 00:01:00Z], nil)])

    older = decoded_summary!() |> summary_with_end("2026-07-11T00:00:10Z")
    newer = decoded_summary!() |> summary_with_end("2026-07-11T00:00:16Z")

    opts = [cache_identity: make_ref(), prior_loader: fn -> {[older, newer], false} end]

    assert {:ok, dataset} = LatestRun.load(file, "new-boot", &ticket_analyzable?/1, opts)
    assert get_in(dataset, [:provenance, :time_range, :end]) == "2026-07-11T00:00:16Z"
  end

  test "returns the empty live fallback when no retained summary exists" do
    file = write_live_file!([route_record("new-boot", 1, "restart", ~U[2026-07-12 00:01:00Z], nil)])

    opts = [cache_identity: make_ref(), prior_loader: fn -> {[], false} end]

    assert {:ok, dataset} = LatestRun.load(file, "new-boot", &ticket_analyzable?/1, opts)
    assert dataset.tickets == %{}
  end

  test "surfaces retained-but-unreadable summaries as a persistence failure" do
    file = write_live_file!([route_record("new-boot", 1, "restart", ~U[2026-07-12 00:01:00Z], nil)])

    opts = [cache_identity: make_ref(), prior_loader: fn -> {[], true} end]

    assert {:error, :retained_unreadable} = LatestRun.load(file, "new-boot", &ticket_analyzable?/1, opts)
  end

  test "reuses decoded prior summaries while the current boot remains empty" do
    {:ok, dataset} = @summary_fixture |> File.read!() |> Summaries.decode_summary()
    cache_identity = make_ref()
    parent = self()

    loader = fn ->
      send(parent, :loaded_prior_summaries)
      {[dataset], false}
    end

    file = write_live_file!([route_record("new-boot", 1, "restart", ~U[2026-07-12 00:01:00Z], nil)])
    opts = [cache_identity: cache_identity, prior_loader: loader]

    assert {:ok, ^dataset} = LatestRun.load(file, "new-boot", &ticket_analyzable?/1, opts)
    assert_received :loaded_prior_summaries

    assert {:ok, ^dataset} = LatestRun.load(file, "new-boot", &ticket_analyzable?/1, opts)
    refute_received :loaded_prior_summaries
  end

  defp write_live_file!(records) do
    root = Path.join(System.tmp_dir!(), "aiur-latest-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")
    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end

  defp route_record(boot_id, sequence, event, timestamp, ticket) do
    attributes =
      %{"event" => event, "boundary" => "point", "event_key" => "route-#{boot_id}-#{sequence}"}
      |> then(fn attributes ->
        if ticket, do: Map.put(attributes, "ticket", ticket), else: attributes
      end)

    %{
      schema_version: 2,
      kind: if(event == "restart", do: "restart", else: "lifecycle"),
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: boot_id,
      sequence: sequence,
      record_id: "#{boot_id}:#{sequence}",
      attributes: attributes
    }
  end
end

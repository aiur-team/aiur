Code.require_file("../../support/progress_renderer_census.exs", __DIR__)

defmodule Aiur.Regression.ProgressRendererBoundaryTest do
  @moduledoc """
  Source census for the RootSummary progress-resolution boundary.

  Progress presentation belongs in `Aiur.BuildOrder.ProgressRenderer`. Build
  Order surfaces may consume its terminal, JSON, or HTML projection, but may
  not reconstruct a two-state completion enum or format raw progress fields.
  The explicit call-site census makes additions deliberate and reviewable.
  """

  use ExUnit.Case, async: true

  alias Aiur.TestSupport.ProgressRendererCensus

  @lib_root Path.expand("../../../lib", __DIR__)

  # These files define or populate the RootSummary progress contract itself
  # rather than presenting it, so they name the resolution fields by necessity.
  @contract_boundary_files [
    "aiur/build_order/github_graph/normalizer.ex",
    "aiur/build_order/progress_renderer.ex",
    "aiur/build_order/root_summary.ex",
    "aiur_web/build_order/planning_source.ex",
    "aiur_web/components/operator_control_center/build_order_grid_model.ex"
  ]

  @renderer_calls %{
    "aiur/build_orders_cli.ex" => [
      "ProgressRenderer.terminal(",
      "ProgressRenderer.terminal(",
      "ProgressRenderer.terminal(",
      "ProgressRenderer.terminal(",
      "ProgressRenderer.json(",
      "ProgressRenderer.json(",
      "ProgressRenderer.json("
    ],
    "aiur_web/components/operator_control_center/build_order_catalog.ex" => ["ProgressRenderer.html("],
    "aiur_web/components/operator_control_center/build_order_graph.ex" => ["ProgressRenderer.html("]
  }

  # These files own separate live-execution progress domains — including the
  # Stream Deck key-face surface, whose contract module and live view render a
  # key's progress bar rather than a Build Order RootSummary. The exact file
  # census keeps the exemption visible without blessing new files or paths.
  # The Units surfaces are one such domain: `units_presentation.ex` holds the
  # progress label lifted out of the already-exempt `units_table.ex`, and
  # `units_cli.ex` reprints that same label for the terminal.
  # Ticket-activity retention is another: `ticket_activity.ex` and
  # `progress_retention.ex` store, serialize, and reload the raw progress
  # reading that the already-exempt `ticket_activity/projection.ex` holds in
  # memory. They persist the reading; they never present it.
  @raw_progress_exempt_files [
    "aiur/agent_list/activation.ex",
    "aiur/agent_list/activity_intake.ex",
    "aiur/build_order/member.ex",
    "aiur/build_order/ticket_history_provider.ex",
    "aiur/current_run_projections/finalizer.ex",
    "aiur/current_run_projections/source_adapter.ex",
    "aiur/current_run_summary/facts.ex",
    "aiur/current_run_summary/progress.ex",
    "aiur/current_run_summary/projection.ex",
    "aiur/current_run_summary/status.ex",
    "aiur/orchestrator/status_report.ex",
    "aiur/progress_retention.ex",
    "aiur/ticket_activity.ex",
    "aiur/ticket_activity/projection.ex",
    "aiur/units_cli.ex",
    "aiur_web/build_order/ticket_context_presenter.ex",
    "aiur_web/build_order_presenter.ex",
    "aiur_web/components/operator_control_center/build_order_breakdown.ex",
    "aiur_web/components/operator_control_center/run_summary.ex",
    "aiur_web/components/operator_control_center/run_summary_strip.ex",
    "aiur_web/components/operator_control_center/ticket_context.ex",
    "aiur_web/components/operator_control_center/units_table.ex",
    "aiur_web/live/streamdeck_live.ex",
    "aiur_web/operator_control_center/run_summary_presenter.ex",
    "aiur_web/operator_control_center/units_presentation.ex",
    "aiur_web/streamdeck_key_face_contract.ex"
  ]

  test "Build Order presentation surfaces do not bypass the shared renderer" do
    offenders = raw_resolution_offenders() ++ (@lib_root |> source_files() |> Enum.flat_map(&raw_progress_offenders/1))

    assert offenders == [], """
    Build Order progress presentation bypasses ProgressRenderer:

    #{Enum.join(offenders, "\n")}

    Pass the contract-shaped value to ProgressRenderer.terminal/1,
    ProgressRenderer.json/1, or ProgressRenderer.html/1. Do not add another
    completion_state/completion_known enum or format a raw percentage.
    """
  end

  test "raw access detector rejects parser-visible bypass forms in any presentation path" do
    source = """
    defmodule FutureAnalytics do
      def dot(entry), do: entry.progress
      def bracket(entry), do: entry[:progress]
      def get(entry), do: Map.get(entry, :progress)
      def fetch(entry), do: Map.fetch(entry, :progress)
      def fetch!(entry), do: Map.fetch!(entry, :progress)
      def nested(entry), do: get_in(entry, [:progress])
      def map_pattern(%{progress: progress}), do: progress
      def struct_pattern(%RootSummary{progress: progress}), do: progress
    end
    """

    offenders = ProgressRendererCensus.offenders("aiur_web/live/future_analytics_live.ex", source)

    assert length(offenders) >= 8
    assert Enum.any?(offenders, &String.contains?(&1, "%{progress: progress}"))
    assert Enum.any?(offenders, &String.contains?(&1, "%RootSummary{progress: progress}"))
  end

  test "renderer call sites match the reviewed census" do
    actual =
      @lib_root
      |> source_files()
      |> Map.new(fn path ->
        relative = Path.relative_to(path, @lib_root)
        source = File.read!(path)

        calls =
          ["ProgressRenderer.terminal(", "ProgressRenderer.json(", "ProgressRenderer.html("]
          |> Enum.flat_map(fn call -> List.duplicate(call, count_occurrences(source, call)) end)

        {relative, calls}
      end)
      |> Map.reject(fn {_file, calls} -> calls == [] end)

    assert actual == @renderer_calls, """
    ProgressRenderer call-site census changed.

    Expected: #{inspect(@renderer_calls, pretty: true)}
    Actual:   #{inspect(actual, pretty: true)}

    New progress surfaces must use the matching shared renderer. If this is a
    legitimate new surface, add its exact call to @renderer_calls so review
    sees the boundary expansion.
    """
  end

  defp source_files(lib_root), do: Path.wildcard(Path.join(lib_root, "**/*.ex")) |> Enum.sort()

  defp raw_resolution_offenders do
    @lib_root
    |> source_files()
    |> Enum.reject(&(Path.relative_to(&1, @lib_root) in @contract_boundary_files))
    |> Enum.flat_map(fn path ->
      relative = Path.relative_to(path, @lib_root)

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(&raw_resolution_offender(&1, relative))
    end)
  end

  defp raw_resolution_offender({line, number}, relative) do
    if String.contains?(line, ["progress_resolution", "progress_resolved_count"]),
      do: ["#{relative}:#{number}: #{String.trim(line)}"],
      else: []
  end

  defp raw_progress_offenders(path) do
    relative = Path.relative_to(path, @lib_root)

    if relative in @contract_boundary_files or relative in @raw_progress_exempt_files,
      do: [],
      else: ProgressRendererCensus.offenders(relative, File.read!(path))
  end

  defp count_occurrences(source, needle), do: source |> :binary.matches(needle) |> length()
end

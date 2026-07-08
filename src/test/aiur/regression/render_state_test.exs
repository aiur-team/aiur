defmodule Aiur.Regression.RenderStateTest do
  @moduledoc """
  Characterization of the App -> Renderer render-state contract (refactor T-012).
  Pins: (1) render-state key threading (a renderer-consumed state field that
  App.render/1 does not thread renders its silent default -- the #414/#473/#730
  class); (2) terminal-state rendering (flag/progress/pause -- #730); (3) a
  full-frame ANSI snapshot of the main board. Read-only for executor agents: if
  one of these tests fails, the production change is wrong.
  """

  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer
  alias Aiur.TestSupport.Snapshot

  @app_source Path.expand("../../../lib/aiur/agent_list/app.ex", __DIR__)
  @renderer_source Path.expand("../../../lib/aiur/agent_list/renderer.ex", __DIR__)

  # Renderer keys App.render/1 deliberately does NOT thread (:now_ms -> clock,
  # :repo_identity -> :project_label). Any OTHER unthreaded key is the #414 bug.
  @intentionally_defaulted MapSet.new([:now_ms, :repo_identity])

  @ansi_green IO.ANSI.green()
  # Frozen clock keeps the spinner + time-based progress deterministic.
  @now 1_000_000

  defp render(state), do: IO.iodata_to_binary(Renderer.render(state))

  defp visible(text), do: Regex.replace(~r/\e\[[?0-9;]*[A-Za-z]/, text, "")

  # Raw (ANSI-bearing) frame line for `id`: glyph/bar assertions apply visible/1,
  # green-tint assertions inspect the raw escapes (mirrors renderer_test.exs).
  defp row_for(out, id) do
    out
    |> String.split(["\r\n", "\n"])
    |> Enum.find(&String.contains?(&1, id))
  end

  defp summary(id, overrides \\ %{}),
    do: Map.merge(%{identifier: id, status: :running, alert_count: 0}, overrides)

  defp rendered_row(overrides, id), do: overrides |> base_state() |> render() |> row_for(id)

  defp base_state(overrides) do
    Map.merge(
      %{
        summaries: [],
        selection_index: 0,
        selection_focus: :agents,
        columns: 120,
        rows: 30,
        project_label: nil,
        dashboard_url: nil,
        agent_kind: nil,
        agent_count: nil,
        max_agents: nil,
        now_ms: @now,
        truecolor?: false
      },
      overrides
    )
  end

  # --- source-parse helpers for the key-threading census ---

  defp atoms_in(text) do
    ~r/:([a-z][a-z0-9_]*\??)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, k] -> String.to_atom(k) end)
    |> MapSet.new()
  end

  defp app_threaded_keys do
    src = File.read!(@app_source)
    [_, rest] = String.split(src, "render_state =", parts: 2)
    [pipeline, _] = String.split(rest, "Renderer.render(render_state)", parts: 2)
    atoms_in(pipeline)
  end

  defp renderer_consumed_keys do
    src = File.read!(@renderer_source)
    get_keys = Regex.scan(~r/Map\.get\(state,\s*:([a-z][a-z0-9_]*\??)/, src)
    dot_keys = Regex.scan(~r/\bstate\.([a-z][a-z0-9_]*\??)/, src)

    (get_keys ++ dot_keys)
    |> Enum.map(fn [_, k] -> String.to_atom(k) end)
    |> MapSet.new()
  end

  describe "render_state key threading (#414/#473/#730)" do
    test "every render-state key the renderer consumes is threaded by App.render/1" do
      threaded = app_threaded_keys()
      consumed = renderer_consumed_keys()

      missing =
        consumed
        |> MapSet.difference(threaded)
        |> MapSet.difference(@intentionally_defaulted)

      assert MapSet.equal?(missing, MapSet.new()), """
      Renderer reads render-state key(s) that App.render/1 never threads: \
      #{inspect(MapSet.to_list(missing))}.
      A consumed-but-unthreaded key renders its silent default (the #414/#473/#730 class).
      Thread each key through the Map.take/Map.put pipeline in \
      src/lib/aiur/agent_list/app.ex render/1.
      """
    end

    test "the intentionally-defaulted keys stay consumed-but-unthreaded (allowlist canary)" do
      threaded = app_threaded_keys()
      consumed = renderer_consumed_keys()

      for key <- MapSet.to_list(@intentionally_defaulted) do
        assert MapSet.member?(consumed, key),
               "#{inspect(key)} is no longer read by the renderer; drop it from @intentionally_defaulted."

        refute MapSet.member?(threaded, key),
               "#{inspect(key)} is now threaded by App.render/1; drop it from @intentionally_defaulted."
      end
    end
  end

  describe "terminal-state rendering (flag/progress/pause -- #730 class)" do
    test "a paused agent renders the pause glyph" do
      row = rendered_row(%{summaries: [summary("T-PAUSE", %{work_state: :paused})], columns: 200}, "T-PAUSE")
      assert visible(row) =~ "⏸️"
    end

    test "a deactivated agent renders the finish flag, never the warming hourglass" do
      row = rendered_row(%{summaries: [summary("T-FLAG", %{work_state: :deactivated})], columns: 200}, "T-FLAG")
      assert visible(row) =~ "🏁"
      refute visible(row) =~ "⏳"
    end

    test "a mid-progress sample renders a partial bar without the green tint" do
      row =
        rendered_row(
          %{summaries: [summary("T-PROG")], columns: 200, progress_by_id: %{"T-PROG" => [{50, @now}]}},
          "T-PROG"
        )

      assert visible(row) =~ "█████░░░░░"
      refute String.contains?(row, @ansi_green)
    end

    test "a 100% sample tints the full bar green" do
      summaries = [summary("T-DONE"), summary("T-SEL")]

      row =
        rendered_row(
          %{summaries: summaries, selection_index: 1, columns: 200, progress_by_id: %{"T-DONE" => [{100, @now}]}},
          "T-DONE"
        )

      assert visible(row) =~ "██████████"
      assert String.contains?(row, @ansi_green)
    end

    test "a row with no progress samples renders the dotted empty track, not a hatched bar" do
      row = rendered_row(%{summaries: [summary("T-IDLE")], columns: 200, progress_by_id: %{}}, "T-IDLE")
      assert visible(row) =~ "··········"
      refute visible(row) =~ "░"
    end
  end

  @fixture_summaries [
    %{identifier: "701", status: :running, alert_count: 0, work_state: :working, runtime_seconds: 125, title: "add widget"},
    %{identifier: "702", status: :running, alert_count: 2, work_state: :paused, runtime_seconds: 640, title: "fix flake"},
    %{identifier: "703", status: :running, alert_count: 0, work_state: :deactivated, runtime_seconds: 3725, title: "shipped"},
    %{identifier: "704", status: :running, alert_count: 0, work_state: :queued, title: "queued work"}
  ]

  defp board_state(columns) do
    base_state(%{
      summaries: @fixture_summaries,
      selection_index: 0,
      columns: columns,
      rows: 30,
      project_label: "applekid/aiur",
      dashboard_url: "http://127.0.0.1:4000/",
      agent_kind: "claude",
      agent_count: 3,
      max_agents: 4,
      now_ms: @now,
      progress_by_id: %{"701" => [{40, @now}], "703" => [{100, @now}]}
    })
  end

  describe "ANSI snapshot of the main board" do
    test "wide board renders the full-width frame" do
      output = render(board_state(180))
      Snapshot.assert_snapshot!("agent_list_snapshots/main_board_wide.snapshot.txt", Snapshot.escape_ansi(output))
    end

    test "narrow board reflows the columns" do
      output = render(board_state(80))
      Snapshot.assert_snapshot!("agent_list_snapshots/main_board_narrow.snapshot.txt", Snapshot.escape_ansi(output))
    end
  end
end

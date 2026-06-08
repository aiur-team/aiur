defmodule Aiur.Regression.WarmMarkerSemanticsTest do
  @moduledoc """
  Regression for "● appeared on agent rows before warm-ready" (reported
  2026-05-21). Two interlocking guarantees the renderer must keep:

  1. 🟢 ONLY appears on running rows whose opencode-attach is fully
     painted and ready to instant-open. Promised by AttachPool's
     `wait_for_paint` gate — if paint times out, we send :attach_failed
     and the identifier never enters warm_identifiers.

  2. ● ONLY appears on rows whose pane is actually visible to the
     user. `visible_sessions` is populated from :slot_session_changed
     which fires during AttachPool's warming (before paint). The
     renderer strips warming + warm ids from visible_sessions so
     ● never paints a row mid-warm.

  3. AttachPool broadcasts {:attach_warming, id, slot} when it
     dispatches a warm Task so AgentList can populate
     warming_identifiers immediately. Without this broadcast there's
     a several-second window where ● would falsely paint.
  """

  use ExUnit.Case, async: true

  alias Aiur.AgentEvents
  alias Aiur.AgentList.{App, Renderer}

  @attach_pool_source Path.expand("../../../lib/aiur/opencode/attach_pool.ex", __DIR__)
  @app_source Path.expand("../../../lib/aiur/agent_list/app.ex", __DIR__)
  @renderer_source Path.expand("../../../lib/aiur/agent_list/renderer.ex", __DIR__)

  defmodule MockPaneManager do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:open, identifier, command, _opts}, _from, parent) do
      send(parent, {:mock_open, identifier, command})
      {:reply, {:ok, "%999"}, parent}
    end
  end

  describe "wait_for_paint gates warm" do
    @describetag :skip
    # Issue #85 retired the warm/warming binary state machine. The new
    # design (1 Slot.attach per agent per slot) doesn't need a paint
    # gate — Slot.set_visible respawns the attach pane with --session
    # synchronously when the user opens an agent. Behavioral coverage
    # of "no false 🟢 / no false ⚪" moves to U11.
    test "AttachPool waits for `Build · issue-` paint before flipping to :warm" do
      source = File.read!(@attach_pool_source)

      assert source =~ ~r/defp wait_for_paint\(pane_id,/,
             "wait_for_paint/2 must exist"

      assert source =~ ~r/"Build · issue-"/,
             """
             wait_for_paint MUST grep for the opencode message-turn
             marker. Anything else (e.g. checking for non-empty
             content) would flip warm before opencode has rendered.
             """
    end

    test "paint_timeout drops the attachment (does NOT mark warm)" do
      source = File.read!(@attach_pool_source)

      # The :timeout branch lives in finish_warm_attach_after_paint/5,
      # the helper that spawn_warm_attach delegates to once Slot.select
      # returns its pane_id.
      paint_block =
        case Regex.run(
               ~r/defp finish_warm_attach_after_paint.*?\n  end\n/s,
               source
             ) do
          [m | _] -> m
          _ -> raise "could not extract finish_warm_attach_after_paint"
        end

      assert paint_block =~ ~r/:timeout ->\s*\n[^}]*?send\(pool, \{:attach_failed/s,
             """
             On wait_for_paint :timeout, finish_warm_attach_after_paint
             MUST send :attach_failed (not :attach_warmed). The ready
             state is a PROMISE that pressing Enter opens opencode in
             <1 s. Marking warm on timeout breaks that promise — the
             user sees 🟢 on a row whose attach is dead or still booting.
             """

      refute paint_block =~
               ~r/:timeout ->\s*\n[^}]*?send\(pool, \{:attach_warmed/s,
             """
             finish_warm_attach_after_paint must NOT send :attach_warmed
             on paint timeout. (Previous version did this as a 'best
             effort' but it lied to the user.)
             """
    end
  end

  describe "● is suppressed during warming + warm" do
    @describetag :skip
    # Issue #85 retired the ● open-pane glyph in favor of the 4-state
    # ⏳ / 🔘 / ⚪ / 🟢 marker. The new model atomically updates
    # visible_in alongside :slot_visible_changed broadcasts — no
    # interleave race exists. Behavioral coverage moves to U11.
    test "AttachPool broadcasts :attach_warming when dispatching warm Task" do
      source = File.read!(@attach_pool_source)

      assert source =~ ~r/broadcast_event\(\{:attach_warming,/,
             """
             AttachPool MUST broadcast :attach_warming as soon as it
             dispatches a warm Task. AgentList listens for this so
             it can add the identifier to warming_identifiers BEFORE
             :slot_session_changed fires from Slot.select. Without
             this broadcast, ● falsely paints on the row for the
             5-15 s window between Slot.select and paint completion.
             """
    end

    test "AgentList tracks warming_identifiers in state" do
      source = File.read!(@app_source)

      assert source =~ ~r/warming_identifiers:\s*MapSet\.new\(\)/,
             "AgentList state MUST initialize warming_identifiers"

      assert source =~ ~r/def handle_info\(\{:attach_warming,/,
             "AgentList MUST handle the :attach_warming PubSub event"
    end

    test "renderer strips warming + warm from visible_identifiers" do
      source = File.read!(@renderer_source)

      visible_block =
        case Regex.run(~r/defp visible_identifiers.*?\n  end\n/s, source) do
          [m | _] -> m
          _ -> raise "could not extract visible_identifiers"
        end

      assert visible_block =~ ~r/MapSet\.difference\(.*warming/,
             """
             visible_identifiers MUST subtract warming_identifiers
             from the raw visible_sessions set. Otherwise ● paints
             on every row whose slot session is selected — including
             warming-in-progress rows where no pane is visible yet.
             """

      assert visible_block =~ ~r/MapSet\.difference\(.*warm/,
             """
             visible_identifiers MUST subtract warm_identifiers too
             (defensive — a warm row should show ready status, not ●).
             """
    end
  end

  describe "warm readiness lives in the status column" do
    @describetag :skip
    # Issue #85 swapped the binary warm/warming state for the 4-state
    # ⏳ / 🔘 / ⚪ / 🟢 model. Render assertions below check the old
    # state names (warming_identifiers / warm_identifiers). Renderer
    # tests for the new state model land alongside U5; behavioral
    # coverage of "🟢 only when actually visible" moves to U11.
    test "running but not warm renders hourglass instead of green" do
      out =
        render_state(%{
          summaries: [
            %{
              identifier: "MT-WARMING",
              status: :running,
              alert_count: 0,
              work_state: :working
            }
          ],
          warming_identifiers: MapSet.new(["MT-WARMING"]),
          warm_identifiers: MapSet.new()
        })

      assert out =~ "⏳"
      refute out =~ "🟢"
    end

    test "warm marker glyph is not rendered in the agent-list UI" do
      out =
        render_state(%{
          summaries: [
            %{
              identifier: "MT-WARM",
              status: :running,
              alert_count: 0,
              work_state: :working
            }
          ],
          warm_identifiers: MapSet.new(["MT-WARM"])
        })

      assert out =~ "🟢"
      refute out =~ "⚡"
    end

    test "enter on a warming row does not open an opencode pane" do
      parent = self()
      {:ok, pane_manager} = start_supervised({MockPaneManager, parent})
      name = Module.concat(__MODULE__, :"App#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        start_supervised(
          {App,
           [
             name: name,
             write_fun: fn _iodata -> :ok end,
             pane_manager: pane_manager,
             orchestrator: self(),
             subscribe?: false,
             command_template: "echo open"
           ]},
          id: name
        )

      send(GenServer.whereis(name), {
        :running_changed,
        [
          Map.put(AgentEvents.agent_summary("MT-WARMING", :running, 0), :work_state, :working)
        ]
      })

      wait_until(fn -> App.snapshot(name).summaries != [] end)
      App.activate(name)

      refute_receive {:mock_open, "MT-WARMING", _command}, 150
    end
  end

  defp render_state(overrides) do
    %{
      summaries: [],
      selection_index: 0,
      columns: 80,
      rows: 20,
      project_label: nil,
      dashboard_url: nil,
      refresh_label: nil,
      agent_kind: nil,
      agent_count: nil,
      max_agents: nil
    }
    |> Map.merge(overrides)
    |> Renderer.render()
    |> IO.iodata_to_binary()
    |> strip_ansi()
  end

  defp strip_ansi(text), do: Regex.replace(~r/\e\[[?0-9;]*[A-Za-z]/, text, "")

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met")
end

defmodule Aiur.BuildQueue.MeasurementTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.BuildQueue.{Model, Server}
  alias Aiur.Config.Schema

  defmodule Boundary do
    def open_issue_labels(_), do: {:ok, Map.new(~w(1 2), &{&1, %{labels: ["agent:queued"]}}), 1_000}
    def blocked_by(_), do: {:ok, []}
    def status(_), do: :unavailable
    def save(_), do: :ok
    def update_issue_state(_, _, _), do: {:error, {:github, :local_hold, %{}}}

    def load do
      queue = %Model.Queue{id: "q", name: "Q", kind: :list, root: nil, held: false, generation: 0, created_at: ~U[2026-10-09 00:00:00Z]}
      items = for id <- ~w(1 2), do: %Model.Item{issue_id: id, queue_id: "q", position: nil, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
      {:ok, %{queues: [queue], items: items, edges: [], intents: [], latches: []}}
    end
  end

  test "server records demand before budget pacing and does not count ready backlog twice" do
    settings = %Schema{build_queue: %Schema.BuildQueue{enabled: true}, tracker: %Schema.Tracker{}, polling: %Schema.Polling{}}

    pid =
      start_supervised!(
        {Server,
         name: nil,
         settings: {:ok, settings},
         tracker: Boundary,
         store: Boundary,
         claim_probe: Boundary,
         clock: fn -> 1_000 end,
         schedule: fn _, _, _ -> make_ref() end,
         exchange: :absent_measurement_exchange}
      )

    log =
      capture_log(fn ->
        token = :sys.get_state(pid).pending
        send(pid, {:reconcile, token})
        assert {:ok, %{reconciles: 1}} = GenServer.call(pid, :show)
        assert :writes_paused = GenServer.call(pid, :status)
        send(pid, :tick)
        GenServer.call(pid, :status)
        token = :sys.get_state(pid).pending
        send(pid, {:reconcile, token})
        assert {:ok, %{reconciles: 2}} = GenServer.call(pid, :show)
      end)

    rows = Regex.scan(~r/build_queue_reconcile (\{[^\n]+\})/, log) |> Enum.map(fn [_, json] -> Jason.decode!(json) end)

    assert Enum.map(rows, &Map.take(&1, ["reconcile", "ready", "newly_ready", "captured_at_ms"])) == [
             %{"reconcile" => 1, "ready" => 2, "newly_ready" => 2, "captured_at_ms" => 1_000},
             %{"reconcile" => 2, "ready" => 2, "newly_ready" => 0, "captured_at_ms" => 1_000}
           ]

    assert Enum.all?(rows, &(&1["freshness"] == "fresh" and &1["phase"] == "ready"))
  end
end

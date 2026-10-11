defmodule Aiur.BuildQueue.ProgressFailureTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.BuildProgress
  alias Aiur.BuildQueue.{Model, Server}
  alias Aiur.Config.Schema

  defmodule Boundary do
    def open_issue_labels(_), do: {:ok, %{"1" => %{labels: ["agent:queued", "agent:in-progress"]}}, 1_000}

    def load do
      queue = %Model.Queue{id: "q-failure", name: "Progress", kind: :list, root: nil, held: false, generation: 0, created_at: ~U[2026-10-08 00:00:00Z]}
      item = %Model.Item{issue_id: "1", queue_id: queue.id, position: 0, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
      {:ok, %{queues: [queue], items: [item], edges: [], intents: [], latches: []}}
    end

    def blocked_by(_), do: {:ok, []}
    def status(_), do: :unavailable
    def save(_), do: :ok
  end

  defmodule FaultyProgress do
    use GenServer
    def start_link(mode), do: GenServer.start_link(__MODULE__, mode, name: Aiur.BuildProgress)
    @impl true
    def init(mode), do: {:ok, mode}
    @impl true
    def handle_call({:put_fact, _}, _from, :error), do: {:reply, {:error, :store_fault}, :error}
    def handle_call({:put_fact, _}, _from, :raise), do: raise("store fault")
  end

  for mode <- [:error, :raise] do
    @tag mode: mode
    test "#{mode} during publication keeps reconciliation alive, unknown, and retryable", %{mode: mode} do
      start_supervised!(%{id: FaultyProgress, start: {FaultyProgress, :start_link, [mode]}, restart: :temporary})
      owner = self()
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
           exchange: :absent_progress_exchange,
           schedule: fn _, message, _ ->
             send(owner, message)
             make_ref()
           end}
        )

      log =
        capture_log(fn ->
          reconcile(pid)
          assert Process.alive?(pid)
          assert GenServer.call(pid, :status) == :running
          assert [%{progress: progress, items: [%{state: :claimed}]}] = GenServer.call(pid, :read_model).queues
          assert progress == %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}
          if mode == :error, do: reconcile(pid)
        end)

      assert length(Regex.scan(~r/Build queue progress publication failed:/, log)) == 1
      stop_supervised(FaultyProgress)
      path = Path.join(Aiur.TestSupport.tmp_root!("queue-progress-failure"), "progress.json")
      start_supervised!({BuildProgress, state_file: path})
      reconcile(pid)
      assert Process.alive?(pid)
      assert [%{progress: %{percent: 0, resolution: :resolved}}] = GenServer.call(pid, :read_model).queues
      assert [%{percent: 0, resolution: :resolved}] = BuildProgress.facts({:queue, "q-failure"})
      assert :sys.get_state(pid).reconciles == if(mode == :error, do: 3, else: 2)
    end
  end

  defp reconcile(pid) do
    GenServer.call(pid, :reconcile_now)
    assert_received {:reconcile, _} = message
    send(pid, message)
    GenServer.call(pid, :status)
  end
end

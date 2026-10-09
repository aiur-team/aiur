defmodule Aiur.BrowserHarness.BuildQueueFixture do
  @moduledoc false
  import Plug.Conn

  @states ~w(running empty disabled unsupported_tracker store_unavailable writes_paused stale unknown)
  @item_states [:waiting, :ready, :promoted, :promoted_unauthorized, :claimed, :held, :overridden, :failed_prerequisite, :completed, :cancelled, :removed]
  @now ~U[2026-10-09 10:00:00Z]

  def init(opts), do: opts
  def call(conn, _opts), do: configure(conn, conn.params)

  def configure(conn, %{"state" => state}) when state in @states do
    Application.put_env(:aiur, :build_queue_dashboard_reader, fn -> view(state) end)
    conn |> put_resp_header("location", "/build-orders") |> send_resp(302, "")
  end

  def configure(conn, _params), do: send_resp(conn, 400, "Unknown queue fixture state")

  def read, do: view("empty")

  def view(state) when state in @states do
    freshness = if state in ~w(stale unknown), do: String.to_existing_atom(state), else: :current
    source = %{state: :ok, observed_at: @now, age_ms: 12_000, freshness: freshness, reasons: []}
    queues = if state == "empty", do: [], else: [queue()]
    status = if state in ~w(empty stale unknown), do: :running, else: String.to_existing_atom(state)

    %{
      model: %{status: status, sources: %{"tracker_observation" => source}, queues: queues},
      attentions: [
        %{"message" => "Queue promotion needs operator attention", "needs_attention" => true, "timestamp" => DateTime.to_iso8601(@now)},
        %{"message" => "Queue prerequisite recovered", "needs_attention" => false, "timestamp" => DateTime.to_iso8601(DateTime.utc_now())}
      ]
    }
  end

  defp queue do
    %{
      queue_id: "q-fixture",
      name: "Release queue",
      held: true,
      items: Enum.with_index(@item_states, 1) |> Enum.map(fn {state, position} -> item(state, position) end),
      progress: %{completed: 1, total: 11, resolved: 11, percent: 9, resolution: :resolved}
    }
  end

  defp item(state, position) do
    %{
      number: 3000 + position,
      position: position,
      state: state,
      reason: nil,
      rank: {0, 2, 0, 0, 0},
      downstream_open: 3,
      prerequisites: [%{number: 2999, verdict: :pending, source: :issue_dependency}],
      attention: if(state == :failed_prerequisite, do: :prerequisite_failed, else: nil)
    }
  end
end

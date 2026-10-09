defmodule Aiur.GitHub.QueueCostTest do
  use ExUnit.Case, async: false
  require Logger
  alias Aiur.GitHub.{Quota, Transport}
  alias Aiur.Orchestrator.TicketTransition

  defmodule Tracker do
    def update_issue_state(id, _state, _opts) do
      request(:get, id, "")
      request(:post, id, "/labels")
      :ok
    end

    def add_label(id, _label), do: write(:post, id, "/labels")
    def remove_label(id, _label), do: write(:delete, id, "/labels/agent%3Atodo")

    defp write(method, id, suffix) do
      {:ok, %{status: 200}} = request(method, id, suffix)
      :ok
    end

    def request(method, id, suffix) do
      Transport.default_request_fun(%{method: method, url: "https://api.github.com/repos/queue/cost/issues/#{id}#{suffix}", token: "test-token", body: %{"labels" => ["agent:todo"]}})
    end
  end

  defmodule BrokenTracker do
    def add_label(_, _), do: raise("tracker failed")
  end

  setup do
    previous = for key <- [:github_transport_test_options, :github_quota_server, :github_budget_enabled?], into: %{}, do: {key, Application.fetch_env(:aiur, key)}
    path = Path.join(Aiur.TestSupport.tmp_root!("queue-cost"), "requests.tsv")
    quota = start_supervised!({Quota, name: nil, request_log_path: path, emit_fun: fn _, _ -> :ok end})
    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:aiur, :github_quota_server, quota)
    Application.put_env(:aiur, :github_budget_enabled?, false)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, []))

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:aiur, key, old)
          :error -> Application.delete_env(:aiur, key)
        end
      end
    end)

    %{quota: quota, path: path}
  end

  test "real transition transport bills queue reads and label methods separately without leaking writer", %{quota: quota, path: path} do
    assert :ok = TicketTransition.write_state("3083", "todo", writer: :build_queue, tracker: Tracker, expected_state: :none)
    assert :ok = TicketTransition.write_marker("3083", :add, "agent:queued", writer: :build_queue, tracker: Tracker)
    assert :ok = TicketTransition.write_marker("3083", :remove, "agent:todo", writer: :build_queue, tracker: Tracker)
    assert Logger.metadata()[:ticket_writer] == nil
    assert {:ok, %{status: 200}} = Tracker.request(:post, "3083", "/labels")

    callers = Map.new(Quota.snapshot(quota).callers, &{&1.caller, &1.calls})
    assert callers["build_queue_write_observe"] == 1
    assert callers["build_queue_label_post"] == 2
    assert callers["build_queue_label_delete"] == 1
    assert Enum.sum(Map.values(callers)) == 5
    assert :ok = Quota.flush_request_log(quota)
    rows = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))
    assert Enum.count(rows, &(Enum.at(&1, 3) == "build_queue_label_post" and Enum.at(&1, 4) == "post")) == 2
    assert Enum.count(rows, &(Enum.at(&1, 3) == "build_queue_label_delete" and Enum.at(&1, 4) == "delete")) == 1
  end

  test "tracker exception restores previous attribution" do
    Logger.metadata(ticket_writer: :outer)
    assert_raise RuntimeError, "tracker failed", fn -> TicketTransition.write_marker("1", :add, "agent:queued", writer: :build_queue, tracker: BrokenTracker) end
    assert Logger.metadata()[:ticket_writer] == :outer
  end
end

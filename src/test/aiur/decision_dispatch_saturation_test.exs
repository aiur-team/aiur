defmodule Aiur.DecisionDispatchSaturationTest do
  use ExUnit.Case, async: false

  import Aiur.DecisionDispatchTestSupport

  alias Aiur.{AlertFeed, DecisionDispatchTasks}

  test "default notifier persists one global saturation and recovery transition" do
    name = unique_name(__MODULE__, "GlobalAlert")
    log_root = Path.join(System.tmp_dir!(), "aiur-decision-dispatch-saturation-#{System.unique_integer([:positive])}")
    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      if original_log_file,
        do: Application.put_env(:aiur, :log_file, original_log_file),
        else: Application.delete_env(:aiur, :log_file)

      File.rm_rf!(log_root)
    end)

    start_supervised!({DecisionDispatchTasks, name: name, max_concurrency: 1, max_pending: 1})
    callback = callback(self())

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :active, blocking_job(self(), :active), callback, name)

    assert_receive {:started, :active, active}, 2_000
    assert :pending = DecisionDispatchTasks.enqueue("AIUR-2", :queued, fn -> :ok end, callback, name)

    for rejected <- [:first_rejection, :second_rejection] do
      assert {:error, :decision_dispatch_overloaded} =
               DecisionDispatchTasks.enqueue("AIUR-3", rejected, fn -> :ok end, callback, name)
    end

    assert Enum.count(AlertFeed.list(log_roots: [log_root]), &(&1["topic"] == "system.decision_dispatch.saturated")) == 1

    send(active, :release)
    assert_receive {:terminal, :queued, :ok}, 2_000

    central_log = File.read!(Path.join(log_root, "alerts.ndjson"))
    assert occurrences(central_log, ~S("name":"system.decision_dispatch.saturated")) == 1

    assert occurrences(central_log, ~S("name":"system.decision_dispatch.saturated.resolved")) ==
             1
  end

  defp occurrences(content, needle), do: content |> String.split(needle) |> length() |> Kernel.-(1)
end

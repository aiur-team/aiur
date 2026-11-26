defmodule Aiur.OperatorNotifyTest do
  # A host app turns `operator.notify.<kind>` into a push on the operator's
  # phone. The export envelope drops every field the catalog does not name, so
  # the notification only reaches the events feed and webhooks with its text
  # when the catalog exports it.
  use Aiur.TestSupport

  alias Aiur.{Alerts, OperatorNotify}
  alias Aiur.Events.Envelope

  test "notify publishes operator.notify.<kind> and the export envelope carries the notification" do
    :ok = Aiur.Events.subscribe("operator.notify.review_ready")

    assert {:ok, id} = OperatorNotify.notify("review_ready", " PR is green ", ticket: "645", url: "https://github.com/o/r/pull/1")
    assert_receive {:event, %{topic: "operator.notify.review_ready"} = event}, 1_000

    assert {:ok, external} = Envelope.to_external(Map.put(event, :id, id), instance: "host/default")
    assert {:ok, _created_at, 0} = DateTime.from_iso8601(external["attrs"]["created_at"])

    assert Map.delete(external["attrs"], "created_at") == %{
             "title" => "Review ready: #645",
             "body" => "PR is green",
             "ticket" => "645",
             "url" => "https://github.com/o/r/pull/1"
           }
  end

  test "an unknown kind, blank text, malformed ticket or non-http url is rejected without publishing" do
    :ok = Aiur.Events.subscribe("operator.notify.info")

    assert {:error, :unknown_kind} = OperatorNotify.notify("urgent", "x")
    assert {:error, :blank_text} = OperatorNotify.notify("info", "  ")
    assert {:error, :invalid_ticket} = OperatorNotify.notify("info", "x", ticket: "6 45")
    assert {:error, :invalid_url} = OperatorNotify.notify("info", "x", url: "javascript:alert(1)")
    refute_receive {:event, %{topic: "operator.notify.info"}}, 200
  end

  describe "stall alerts" do
    setup do
      :ok = Aiur.Events.subscribe("operator.notify.stalled")
    end

    test "a stall that opens notifies once with its ticket; a repeat while it is firing does not" do
      assert :ok = OperatorNotify.on_alert("ticket.632.agent.stalled", "worker stalled", fn -> :ok end, condition_state: fn _ -> :resolved end)
      assert_receive {:event, %{topic: "operator.notify.stalled", title: "Stalled: #632", body: "worker stalled", ticket: "632"}}, 1_000

      assert :ok = OperatorNotify.on_alert("ticket.632.agent.stalled", "worker stalled", fn -> :ok end, condition_state: fn _ -> :firing end)
      refute_receive {:event, %{topic: "operator.notify.stalled"}}, 200
    end

    test "resolutions, other alerts and a failed alert emit notify nobody" do
      opening = [condition_state: fn _ -> :unknown end]

      assert :ok = OperatorNotify.on_alert("ticket.632.agent.stalled.resolved", "recovered", fn -> :ok end, opening)
      assert :ok = OperatorNotify.on_alert("system.github.quota.core.exhausted", "quota", fn -> :ok end, opening)
      assert {:error, :ledger} = OperatorNotify.on_alert("ticket.632.agent.stalled", "stalled", fn -> {:error, :ledger} end, opening)
      refute_receive {:event, %{topic: "operator.notify.stalled"}}, 200
    end

    test "the dispatch-cycle stall alert notifies once, through the real alert path" do
      log_root = Aiur.TestSupport.tmp_root!("aiur-operator-notify")
      original_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(log_root) end)
      Aiur.TestSupport.put_runtime_state_dir!(log_root)

      on_exit(fn ->
        if original_log_file, do: Application.put_env(:aiur, :log_file, original_log_file), else: Application.delete_env(:aiur, :log_file)
      end)

      alert = fn -> Alerts.emit_system("system.dispatch.cycle_stalled", message: "dispatch cycle stalled", reason: "no cycle in 10m", needs_attention: true, severity: "warning") end

      assert :ok = alert.()
      assert_receive {:event, %{topic: "operator.notify.stalled", title: "Stalled", body: "dispatch cycle stalled", ticket: nil}}, 1_000

      assert :ok = alert.()
      refute_receive {:event, %{topic: "operator.notify.stalled"}}, 200
    end
  end
end

defmodule Aiur.SignalAlertOrderTest do
  use Aiur.TestSupport

  alias Aiur.{AgentPubSub, AlertLedger, Alerts, Signal}
  alias Aiur.Config.Paths
  alias Aiur.Events.Exchange
  alias AiurWeb.ObservabilityPubSub

  # Characterization guard for the existing persistence, sound and broadcast order.
  for emitter <- [Alerts, Signal] do
    test "#{emitter} preserves files and ordered side effects" do
      identifier = "SIGNAL-ORDER"
      topic = "ticket.#{identifier}.issue.state.changed"
      workspace = Aiur.TestSupport.tmp_root!("signal-order")
      write_workflow_file!(Workflow.workflow_file_path(), alerts_enabled: true)
      :ok = Exchange.subscribe(topic)
      :ok = AgentPubSub.subscribe_agent(identifier)
      :ok = ObservabilityPubSub.subscribe()

      player = fn sound ->
        for path <- [Path.join(workspace, "logs/agent.ndjson"), AlertLedger.path(), Path.join(Paths.log_root_dir(), "alerts.ndjson")] do
          entries = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
          assert Enum.any?(entries, &(&1["topic"] == topic and &1["message"] == "Signal order"))
        end

        {:messages, messages} = Process.info(self(), :messages)
        assert Enum.any?(messages, &match?({:event, %{topic: ^topic}}, &1))
        refute Enum.any?(messages, &match?({:alert, %{name: ^topic}}, &1))
        send(self(), {:played_sound, sound})
      end

      emit = if unquote(emitter) == Alerts, do: &Alerts.emit_system/2, else: &Signal.alert/2
      caller = self()
      tracer = spawn(fn -> collect_sends([]) end)
      on_exit(fn -> Process.exit(tracer, :kill) end)
      :erlang.trace(caller, true, [:send, {:tracer, tracer}])

      try do
        assert :ok = emit.(topic, issue: identifier, workspace: workspace, central: true, message: "Signal order", player: player)
      after
        :erlang.trace(caller, false, [:send])
      end

      ref = :erlang.trace_delivered(caller)
      receive_barrier({:trace_delivered, ^caller, ^ref})
      send(tracer, {:collect, caller})
      receive_barrier({:sends, messages})

      effects =
        Enum.filter(messages, fn
          {:event, %{topic: ^topic}} -> true
          {:played_sound, _} -> true
          {:alert, %{name: ^topic}} -> true
          {:observability_updated, _} -> true
          _ -> false
        end)

      assert [{:event, event}, {:played_sound, sound}, {:alert, alert}, {:observability_updated, event_id}] = effects
      assert event.source == :system
      assert alert.message == "Signal order"
      assert sound == Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
      assert is_integer(event_id) and event_id > 0
    end
  end

  # Trace only this emitter's sends so unrelated singleton refreshes cannot affect order.
  defp collect_sends(messages) do
    receive do
      {:trace, caller, :send, message, caller} -> collect_sends([message | messages])
      {:trace, _, :send, _, _} -> collect_sends(messages)
      {:collect, caller} -> send(caller, {:sends, Enum.reverse(messages)})
    end
  end
end

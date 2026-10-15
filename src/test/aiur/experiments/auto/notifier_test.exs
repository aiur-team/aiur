defmodule Aiur.Experiments.Auto.NotifierTest do
  use Aiur.TestSupport
  alias Aiur.Experiments.Auto.Notifier
  alias Aiur.JsonStore

  setup do
    root = Aiur.TestSupport.tmp_root!("experiment-notifier")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{path: Path.join(root, "latches.json"), spec: %{"id" => "exp-1", "report_reason" => "guard_met", "notes" => "private report"}}
  end

  test "each event persists before publishing and never repeats across a restart", %{path: path, spec: spec} do
    owner = self()

    publish = fn topic, payload ->
      assert {:ok, latches} = JsonStore.read(path)
      assert latches[Jason.encode!(["exp-1", List.last(String.split(topic, "."))])] == true
      send(owner, {:published, topic, payload})
      :ok
    end

    opts = [name: nil, path: path, publish: publish]
    notifier = start_supervised!({Notifier, opts})

    for event <- ~w(preregister report_due cancelled) do
      assert :ok = Notifier.notify(spec, event, notifier)
      topic = "system.experiment.exp-1.#{event}"
      assert_received {:published, ^topic, %{experiment_id: "exp-1", reason: "guard_met", line_source: "manual"} = payload}
      assert Enum.sort(Map.keys(payload)) == [:experiment_id, :line_source, :reason]
      assert :ok = Notifier.notify(spec, event, notifier)
      refute_received {:published, ^topic, _payload}
    end

    stop_supervised!(Notifier)
    notifier = start_supervised!({Notifier, opts})
    for event <- ~w(preregister report_due cancelled), do: assert(:ok = Notifier.notify(spec, event, notifier))
    refute_received {:published, _topic, _payload}
  end

  test "a failed write publishes nothing and the next attempt retries", %{path: path, spec: spec} do
    owner = self()

    write = fn target, latches ->
      case File.read(target <> ".retry") do
        {:ok, _bytes} ->
          JsonStore.write!(target, latches)

        _missing ->
          File.write!(target <> ".retry", "retry")
          {:error, :enospc}
      end
    end

    notifier =
      start_supervised!(
        {Notifier,
         name: nil,
         path: path,
         write: write,
         publish: fn topic, _ ->
           send(owner, {:published, topic})
           :ok
         end}
      )

    assert {:error, :enospc} = Notifier.notify(spec, "report_due", notifier)
    refute_received {:published, _topic}
    refute File.exists?(path)
    assert :ok = Notifier.notify(spec, "report_due", notifier)
    assert_received {:published, "system.experiment.exp-1.report_due"}
  end

  test "corrupt latches disable publishing without replacing the evidence", %{path: path, spec: spec} do
    File.write!(path, "corrupt")
    notifier = start_supervised!({Notifier, name: nil, path: path, publish: fn _, _ -> flunk("must not publish") end})
    assert Notifier.status(notifier) == :degraded
    assert {:error, :degraded} = Notifier.notify(spec, "report_due", notifier)
    assert File.read!(path) == "corrupt"
  end

  test "a failed publication remains latched, preferring a miss over a duplicate", %{path: path, spec: spec} do
    owner = self()

    opts = [
      name: nil,
      path: path,
      publish: fn _, _ ->
        send(owner, :attempted)
        {:error, :unavailable}
      end
    ]

    notifier = start_supervised!({Notifier, opts})
    assert {:error, :unavailable} = Notifier.notify(spec, "report_due", notifier)
    assert_received :attempted
    stop_supervised!(Notifier)
    notifier = start_supervised!({Notifier, opts})
    assert :ok = Notifier.notify(spec, "report_due", notifier)
    refute_received :attempted
  end
end

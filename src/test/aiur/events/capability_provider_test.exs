defmodule Aiur.Events.CapabilityProviderTest do
  use ExUnit.Case, async: false
  alias Aiur.Events.{CapabilityProvider, Export}
  alias Aiur.Events.Export.{Exporter, Layout}

  @context %{
    run_shape: %{http_listener: true},
    settings: %{events: %{export: %{enabled: true, retention_days: 3, retention_max_events: 12_000}}}
  }

  setup do
    root = Path.join(System.tmp_dir!(), "capability-export-#{System.unique_integer([:positive])}")
    previous = :persistent_term.get({Export, :status}, nil)

    on_exit(fn ->
      if previous, do: :persistent_term.put({Export, :status}, previous), else: :persistent_term.erase({Export, :status})
      Aiur.TestCleanup.rm_rf!(root)
    end)

    opts = [identity: fn -> {:ok, "capability-test"} end, directory: fn -> {:ok, root} end, subscribe: fn _ -> :ok end]
    {:ok, root: root, opts: opts}
  end

  test "disabled export is unavailable/disabled" do
    context = put_in(@context.settings.events.export, %Aiur.Config.Schema.EventsExport{})
    assert entry(context) == %{state: :unavailable, reason: :disabled}
  end

  test "enabled but no dashboard is unavailable/not_running", ctx do
    start_exporter(ctx.opts)
    assert entry(put_in(@context.run_shape.http_listener, false)) == %{state: :unavailable, reason: :not_running}
  end

  test "stopped exporter cannot advertise stale healthy status", ctx do
    start_exporter(ctx.opts)
    healthy = Export.status()
    stop_supervised!(Exporter)
    :persistent_term.put({Export, :status}, healthy)
    assert entry(@context) == %{state: :unavailable, reason: :not_running}
  end

  test "enabled and healthy reports v and configured retention without calling exporter", ctx do
    pid = start_exporter(ctx.opts)
    :sys.suspend(pid)

    try do
      assert entry(@context) == %{
               state: :available,
               version: 1,
               v: 1,
               retention: %{max_age_s: 259_200, max_records: 12_000},
               head_seq: 1
             }
    after
      :sys.resume(pid)
    end
  end

  test "corrupt journal is degraded, not available", ctx do
    start_exporter(ctx.opts)
    stop_supervised!(Exporter)
    path = Layout.segment(ctx.root, 1)
    File.write!(path, File.read!(path) <> "broken\n" <> File.read!(path))
    start_exporter(ctx.opts)
    assert entry(@context) == %{state: :degraded, reason: :journal_corrupt}
  end

  test "identity failure is a dependency failure", ctx do
    start_exporter(Keyword.put(ctx.opts, :identity, fn -> {:error, :identity_unavailable} end))
    assert entry(@context) == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["identity"]}
  end

  test "other exporter failures and unavailable settings stay unknown", ctx do
    start_exporter(Keyword.put(ctx.opts, :directory, fn -> {:error, :not_qualified} end))
    assert entry(@context) == %{state: :unknown, reason: :unknown}
    assert entry(%{@context | settings: :unavailable}) == %{state: :unknown, reason: :unknown}
  end

  defp start_exporter(opts) do
    pid = start_supervised!({Exporter, opts})
    :sys.get_state(pid)
    pid
  end

  defp entry(context), do: CapabilityProvider.capabilities(context)["events.export"]
end

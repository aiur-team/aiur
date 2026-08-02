defmodule Aiur.Orchestrator.ControlLifecycleStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.{ControlLifecycle, ControlLifecycleStore}
  alias Aiur.TrackerIdentity

  @now ~U[2026-07-13 12:00:00Z]

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-control-lifecycle-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :control_lifecycle_store_path)
      else
        Application.put_env(:aiur, :control_lifecycle_store_path, previous)
      end

      File.rm(path)
    end)

    :ok
  end

  test "persists redacted records and expires unresolved controls during recovery" do
    lifecycle = ControlLifecycle.new(now: @now)

    {:ok, _request, lifecycle} =
      ControlLifecycle.request(lifecycle, attrs(), now: @now)

    {:ok, _accepted, lifecycle} = ControlLifecycle.accept(lifecycle, "pause-1", 7, now: @now)
    assert :ok = ControlLifecycleStore.save(lifecycle)

    recovered = ControlLifecycleStore.load()
    assert %{status: :accepted} = ControlLifecycle.get(recovered, "pause-1")

    recovered = ControlLifecycleStore.expire_unresolved_on_recovery(recovered, now: @now)

    assert %{status: :expired, expiry: %{reason: :daemon_restart}} = ControlLifecycle.get(recovered, "pause-1")
    assert :ok = ControlLifecycleStore.save(recovered)
    refute File.read!(ControlLifecycleStore.path_for()) =~ "workspace"
  end

  defp attrs do
    %{
      request_id: "pause-1",
      issue_id: "issue-1",
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "I_kwDOissue1",
        identifier: "101",
        reason: nil
      },
      action: :pause,
      generation: 7,
      expected_status: :working,
      expected_version: 0,
      requester: :operator,
      metadata: %{workspace: "/private/workspace"}
    }
  end
end

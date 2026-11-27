defmodule Aiur.Executor.StatusTest do
  use ExUnit.Case, async: false

  alias Aiur.Executor.{HarnessState, Session, Status}
  alias Aiur.TestSupport.Isolation

  test "a timed-out harness projection is unavailable and leaves the binding readable", context do
    root = Aiur.TestSupport.tmp_root!("executor-status")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    Isolation.with_app_env!(:aiur, :executor_state_dir, root)
    {pubsub, _topic} = Isolation.start_pubsub!(context)
    start_supervised!({Session, instance_key: "status-timeout"})
    harness_state = start_supervised!({HarnessState, pubsub: pubsub, interval_ms: nil})
    assert {:ok, %{binding_id: id}} = Session.attach(%{harness: "claude"})

    :ok = :sys.suspend(harness_state)

    try do
      assert %{attached: true, binding: %{binding_id: ^id}, harness_state: :unavailable, read_capability: %{reason: :awaiting_first_hook}} =
               Status.snapshot()
    after
      :ok = :sys.resume(harness_state)
    end
  end
end

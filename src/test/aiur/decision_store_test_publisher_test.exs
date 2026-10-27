defmodule Aiur.DecisionStoreTestPublisherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.DecisionStore

  test "test default answer publisher is a no-op" do
    dir = Aiur.TestSupport.tmp_root!("decision-store-test-publisher")

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    decision = %{
      decision_id: "dec_test_publisher",
      answer: %{action_id: "action_test_publisher"}
    }

    log =
      capture_log(fn ->
        store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end})
        publisher = :sys.get_state(store).answer_comment_publisher
        assert :skip = publisher.(decision)
        refute_receive {:github_request, _, _}, 100
      end)

    refute log =~ "phase=publish_failed"
  end
end

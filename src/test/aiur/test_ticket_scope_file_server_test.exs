defmodule Aiur.TestTicketScopeFileServerTest do
  use ExUnit.Case, async: false

  # open-games, 2026-11-20 (#8051): after the pinned-ticket lookup was cached,
  # the orchestrator watchdog still caught it blocked in `:file.get_cwd/0`,
  # which queues behind the node's one file server like any other file call.
  # A warm lookup must answer while the file server is busy.

  test "a cached pinned-ticket lookup answers while the file server is stuck" do
    assert System.get_env("AIUR_DEV_TEST_TICKET_IDS") == nil
    assert is_boolean(Aiur.TestTicketScope.allowed_identifier?("1"))

    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)

    try do
      task = Task.async(fn -> Aiur.TestTicketScope.allowed_identifier?("1") end)
      assert {:ok, answer} = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
      assert is_boolean(answer)
    after
      :sys.resume(file_server)
    end
  end
end

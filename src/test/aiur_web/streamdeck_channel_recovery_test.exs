defmodule AiurWeb.StreamdeckChannelRecoveryTest do
  use AiurWeb.StreamdeckChannelCase

  # A sibling module that stopped the financial-data tree left Generation absent,
  # and every Stream Deck test then failed `issue_token/0` with
  # `:authentication_required` (#4695). The case setup must bring it back.
  setup_all do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, AiurWeb.FinancialData.Supervisor)
    :ok
  end

  test "a stopped financial-data tree is restarted before the socket authenticates" do
    assert is_pid(Process.whereis(FinancialDataAccess.Generation))
    assert {:ok, _token} = StreamdeckAuth.issue_token()
  end
end

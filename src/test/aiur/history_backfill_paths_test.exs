defmodule Aiur.HistoryBackfillPathsTest do
  use ExUnit.Case, async: false
  alias Aiur.Config.Paths

  test "backfill checkpoint path is private beneath decision state or explicitly overridden" do
    original = Application.get_env(:aiur, :history_backfill_state_dir)

    on_exit(fn ->
      if is_nil(original), do: Application.delete_env(:aiur, :history_backfill_state_dir), else: Application.put_env(:aiur, :history_backfill_state_dir, original)
    end)

    root = Aiur.TestSupport.tmp_root!("history-backfill-path")
    Application.put_env(:aiur, :history_backfill_state_dir, root)
    assert Paths.history_backfill_state_dir() == {:ok, root}
    Application.delete_env(:aiur, :history_backfill_state_dir)
    {:ok, decisions} = Paths.decision_state_dir()
    assert Paths.history_backfill_state_dir() == {:ok, Path.join(decisions, "history-backfill")}
  end
end

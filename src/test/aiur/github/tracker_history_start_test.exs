defmodule Aiur.GitHub.TrackerHistoryStartTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.History
  alias Aiur.GitHub.Tracker

  defmodule Client do
    def update_issue_state(_id, "fail"), do: {:error, :boom}
    def update_issue_state(_id, _state), do: :ok
    def update_issue_state(_id, _state, fail: true), do: {:error, :boom}
    def update_issue_state(_id, _state, _opts), do: :ok
  end

  setup do
    prior = Application.get_env(:aiur, :github_client_module)
    Application.put_env(:aiur, :github_client_module, Client)
    on_exit(fn -> if prior, do: Application.put_env(:aiur, :github_client_module, prior), else: Application.delete_env(:aiur, :github_client_module) end)
    dir = Aiur.TestSupport.tmp_root!("tracker-history")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "both successful state write arities journal starts, failed and unrelated writes do not", %{dir: dir} do
    pid = start_supervised!({History, name: __MODULE__.Store, repository: "acme/widgets", state_dir: dir, flush_ms: 60_000})
    original = Process.whereis(History)
    if original, do: Process.unregister(History)
    Process.unregister(__MODULE__.Store)
    Process.register(pid, History)

    on_exit(fn ->
      if Process.whereis(History) == pid, do: Process.unregister(History)
      if original && Process.alive?(original), do: Process.register(original, History)
    end)

    before = DateTime.utc_now()
    assert :ok = Tracker.update_issue_state("11", "in-progress")
    assert :ok = Tracker.update_issue_state("12", "In Progress", [])
    assert {:error, :boom} = Tracker.update_issue_state("13", "in-progress", fail: true)
    assert {:error, :boom} = Tracker.update_issue_state("14", "fail")
    assert :ok = Tracker.update_issue_state("15", "human-review")
    assert :ok = Tracker.update_issue_state("ABC-12", "in-progress")
    assert :ok = History.note_start("0", :dispatch, before)
    assert :ok = History.note_start("12suffix", :dispatch, before)
    assert {:ok, snapshot} = History.snapshot()
    assert Map.keys(snapshot.rows) |> Enum.sort() == [11, 12]

    for number <- [11, 12] do
      row = snapshot.rows[number]
      assert DateTime.compare(row.in_progress_at, before) != :lt
      assert row.start == row.in_progress_at
      assert row.start_source == :label
    end
  end

  test "store absent leaves state writes unchanged" do
    original = Process.whereis(History)
    if original, do: Process.unregister(History)

    try do
      assert Process.whereis(History) == nil
      assert :ok = Tracker.update_issue_state("1", "in-progress")
      assert :ok = Tracker.update_issue_state("2", "in-progress", [])
    after
      if original && Process.alive?(original), do: Process.register(original, History)
    end
  end
end

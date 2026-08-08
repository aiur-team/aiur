defmodule Aiur.AsksTest do
  use ExUnit.Case, async: false

  alias Aiur.{Asks, RepoBase}

  setup do
    root = Path.join(System.tmp_dir!(), "aiur_asks_#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, root)

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      File.rm_rf!(root)
    end)

    {:ok, repo: "https://github.com/owner/repo.git"}
  end

  test "persists a blocking ask with its command block and executor attribution", %{repo: repo} do
    body = "gh auth refresh -h github.com -s workflow\ngh auth token\n"

    assert {:ok, ask} =
             Asks.create(repo, %{title: "Enable CI readiness", body: body, urgency: "high", blocking: true})

    assert ask["id"] =~ ~r/^ask_[A-Za-z0-9_-]+$/
    assert ask["created_by"] == "executor"
    assert {:ok, _timestamp, _offset} = DateTime.from_iso8601(ask["created_at"])
    assert {:ok, [persisted]} = Asks.open(repo)
    assert persisted["body"] == body
    assert persisted["blocking"]
    assert File.exists?(RepoBase.asks_path(repo))
  end

  test "resolution hides an ask from open reads while retaining its note in all reads", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "Refresh credentials", urgency: "normal", blocking: false})
    assert {:ok, resolved} = Asks.resolve(repo, ask["id"], "workflow scope granted")

    assert resolved["status"] == "done"
    assert resolved["note"] == "workflow scope granted"
    assert resolved["resolved_by"] == "executor"
    assert {:ok, []} = Asks.open(repo)
    assert {:ok, [persisted]} = Asks.all(repo)
    assert persisted["status"] == "done"
    assert persisted["note"] == "workflow scope granted"
  end

  test "does not resolve an ask twice", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "One time", urgency: "low", blocking: false})
    assert {:ok, _} = Asks.resolve(repo, ask["id"])
    assert {:error, message} = Asks.resolve(repo, ask["id"])
    assert message =~ "already done"
  end
end

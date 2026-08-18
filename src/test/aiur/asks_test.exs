defmodule Aiur.AsksTest do
  use ExUnit.Case, async: false

  alias Aiur.{Asks, RepoBase}

  setup do
    # Host-unique, not just VM-unique: another `mix test` VM on this host used to
    # pick the same name and build its state tree inside the directory this
    # teardown was removing. See `Aiur.TestSupport.tmp_root!/1`.
    root = Aiur.TestSupport.tmp_root!("aiur_asks")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, root)

    on_exit(fn ->
      # Restore the global first, so nothing new can resolve into `root`, and
      # only then remove it.
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      remove_state_root!(root)
    end)

    {:ok, repo: "https://github.com/owner/repo.git"}
  end

  # `File.rm_rf!/1` reports only the reason and the path it gave up on, which is
  # what made the original failure ("file already exists" on a recursive remove)
  # read as a mystery for three separate investigations. Name the entries that
  # survived: they identify the writer.
  defp remove_state_root!(root) do
    case File.rm_rf(root) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        survivors = root |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.map(&Path.relative_to(&1, root))

        raise "could not remove the state root #{root}: #{inspect(reason)} at #{path}. " <>
                "Surviving entries (something wrote into the tree while it was being removed): #{inspect(survivors)}"
    end
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
    assert {:error, {:ask_already_done, ask_id}} = Asks.resolve(repo, ask["id"])
    assert ask_id == ask["id"]
  end

  test "allows exactly one concurrent resolution", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "One winner", urgency: "high", blocking: true})

    results =
      1..2
      |> Task.async_stream(fn _ -> Asks.resolve(repo, ask["id"], "handled") end, max_concurrency: 2, timeout: 10_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.any?(results, &match?({:error, {:ask_already_done, _}}, &1))
    assert {:ok, [persisted]} = Asks.all(repo)
    assert persisted["status"] == "done"
  end

  test "rejects invalid event transitions", %{repo: repo} do
    path = RepoBase.asks_path(repo)
    :ok = Aiur.RepoBase.ensure_state_tree(repo)

    orphan_done = %{
      "id" => "ask_orphan",
      "status" => "done",
      "resolved_at" => "2026-08-08T12:00:00Z",
      "resolved_by" => "executor",
      "note" => nil
    }

    File.write!(path, Jason.encode!(orphan_done) <> "\n")

    assert {:error, {:invalid_ask_record, ^path, 1, message}} = Asks.all(repo)
    assert message == {:invalid_ask_transition, :orphan_done}
  end

  test "rejects duplicate or reopened asks", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "Immutable history", urgency: "normal", blocking: false})
    assert {:ok, _} = Asks.resolve(repo, ask["id"])
    path = RepoBase.asks_path(repo)

    File.write!(path, Jason.encode!(ask) <> "\n", [:append])

    assert {:error, {:invalid_ask_record, ^path, 3, message}} = Asks.all(repo)
    assert message == {:invalid_ask_transition, :duplicate_open}
  end

  test "recovers a truncated final append without hiding earlier open asks", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "Still visible", urgency: "high", blocking: true})
    File.write!(RepoBase.asks_path(repo), "{\"id\":\"ask_partial", [:append])

    assert {:ok, [persisted]} = Asks.open(repo)
    assert persisted["id"] == ask["id"]
    assert File.read!(RepoBase.asks_path(repo)) =~ ~r/\n$/
  end

  test "restores a missing final newline before the next append", %{repo: repo} do
    assert {:ok, first} = Asks.create(repo, %{title: "First", urgency: "normal", blocking: false})
    path = RepoBase.asks_path(repo)
    contents = File.read!(path)
    File.write!(path, String.trim_trailing(contents, "\n"))

    assert {:ok, second} = Asks.create(repo, %{title: "Second", urgency: "normal", blocking: false})
    assert {:ok, asks} = Asks.all(repo)
    assert Enum.map(asks, & &1["id"]) |> MapSet.new() == MapSet.new([first["id"], second["id"]])
  end
end

defmodule Aiur.Opencode.DbTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.Db
  alias Exqlite.Basic

  setup do
    db_path =
      Path.join(System.tmp_dir!(), "aiur-opencode-db-test-#{System.unique_integer([:positive])}.db")

    initialize_schema!(db_path)
    Application.put_env(:aiur, :opencode_db_path_override, db_path)

    on_exit(fn ->
      Application.delete_env(:aiur, :opencode_db_path_override)
      File.rm_rf(db_path)
      File.rm_rf(db_path <> "-shm")
      File.rm_rf(db_path <> "-wal")
    end)

    %{db_path: db_path}
  end

  describe "id generators" do
    test "msg_id/0 returns prefixed string matching ^msg pattern" do
      id = Db.msg_id()
      assert String.starts_with?(id, "msg_")
      assert Regex.match?(~r/^msg_[A-Z0-9]+$/, id)
    end

    test "prt_id/0 returns prefixed string matching ^prt pattern" do
      id = Db.prt_id()
      assert String.starts_with?(id, "prt_")
      assert Regex.match?(~r/^prt_[A-Z0-9]+$/, id)
    end

    test "call_id/0 returns prefixed string" do
      assert String.starts_with?(Db.call_id(), "call_")
    end

    test "ids are unique across consecutive calls" do
      ids = for _ <- 1..100, do: Db.msg_id()
      assert Enum.uniq(ids) == ids
    end
  end

  describe "insert + fetch round-trip" do
    test "insert_message + insert_part are visible via fetch_message_with_parts", %{db_path: db_path} do
      with_db_path(db_path, fn ->
        session_id = "ses_test_#{System.unique_integer([:positive])}"
        message_id = Db.msg_id()
        part_id = Db.prt_id()

        message_data = %{
          "role" => "assistant",
          "parentID" => "msg_root_synthetic",
          "modelID" => "issue-13",
          "providerID" => "aiur"
        }

        part_data = %{"type" => "text", "text" => "hello world"}

        assert :ok = Db.insert_message(session_id, message_id, message_data)
        assert :ok = Db.insert_part(session_id, message_id, part_id, part_data)

        assert {:ok, %{message: stored_msg, parts: parts}} =
                 Db.fetch_message_with_parts(session_id, message_id)

        assert stored_msg["role"] == "assistant"
        assert stored_msg["modelID"] == "issue-13"
        assert [%{"type" => "text", "text" => "hello world"}] = parts
      end)
    end

    test "fetch_message_with_parts returns :not_found for unknown id", %{db_path: db_path} do
      with_db_path(db_path, fn ->
        assert {:error, :not_found} = Db.fetch_message_with_parts("ses_x", "msg_does_not_exist")
      end)
    end
  end

  describe "constraint enforcement" do
    test "inserting the same message id twice returns an error", %{db_path: db_path} do
      with_db_path(db_path, fn ->
        session_id = "ses_dup"
        message_id = Db.msg_id()
        data = %{"role" => "assistant"}

        assert :ok = Db.insert_message(session_id, message_id, data)
        assert {:error, _reason} = Db.insert_message(session_id, message_id, data)
      end)
    end
  end

  describe "concurrency" do
    test "parallel inserts to different messages all succeed", %{db_path: db_path} do
      with_db_path(db_path, fn ->
        session_id = "ses_concurrent"

        results =
          1..20
          |> Task.async_stream(
            fn _ ->
              Db.insert_message(session_id, Db.msg_id(), %{"role" => "assistant"})
            end,
            max_concurrency: 8,
            ordered: false
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.all?(results, &(&1 == :ok))
      end)
    end
  end

  # ----------------------------------------------------------------- helpers

  defp with_db_path(path, fun) do
    original = Application.get_env(:aiur, :opencode_db_path_override)
    Application.put_env(:aiur, :opencode_db_path_override, path)

    try do
      fun.()
    after
      case original do
        nil -> Application.delete_env(:aiur, :opencode_db_path_override)
        value -> Application.put_env(:aiur, :opencode_db_path_override, value)
      end
    end
  end

  defp initialize_schema!(path) do
    {:ok, conn} = Basic.open(path)

    statements = [
      "CREATE TABLE IF NOT EXISTS message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)",
      "CREATE TABLE IF NOT EXISTS part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
    ]

    Enum.each(statements, fn sql ->
      {:ok, _, _, _} = Basic.exec(conn, sql)
    end)

    Basic.close(conn)
    :ok
  end
end

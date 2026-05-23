defmodule Aiur.Opencode.SessionWriterTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.SessionWriter
  alias Exqlite.Basic

  describe "await_replay/2" do
    test "returns {:error, :no_writer} when called against a dead pid" do
      # We can't easily spin up a real SessionWriter here without a live
      # opencode SQLite + IssueLog fixture (see Aiur.Opencode.SessionWriterRegistry
      # tests and the U4 AgentAttach integration test for the live path).
      # This guards the public API surface and the no-writer error branch.
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(pid)

      assert SessionWriter.await_replay(pid, 100) == {:error, :no_writer}
    end

    test "returns {:error, :timeout} when GenServer does not reply in time" do
      # A bare GenServer.server() that never replies is enough to exercise
      # the timeout branch — we don't need a real SessionWriter here.
      {:ok, dummy} =
        GenServer.start_link(
          Aiur.Opencode.SessionWriterTest.NeverReplies,
          nil
        )

      assert SessionWriter.await_replay(dummy, 50) == {:error, :timeout}
      GenServer.stop(dummy)
    end
  end

  describe "live event coalescing" do
    setup do
      db_path =
        Path.join(
          System.tmp_dir!(),
          "aiur-session-writer-test-#{System.unique_integer([:positive])}.db"
        )

      initialize_schema!(db_path)
      original = Application.get_env(:aiur, :opencode_db_path_override)
      Application.put_env(:aiur, :opencode_db_path_override, db_path)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:aiur, :opencode_db_path_override)
          value -> Application.put_env(:aiur, :opencode_db_path_override, value)
        end

        File.rm_rf(db_path)
        File.rm_rf(db_path <> "-shm")
        File.rm_rf(db_path <> "-wal")
      end)

      %{db_path: db_path}
    end

    test "writes rapid transcript events as one assistant message", %{db_path: db_path} do
      identifier = "session-writer-coalesce-#{System.unique_integer([:positive])}"
      session_id = "ses_coalesce_#{System.unique_integer([:positive])}"

      {:ok, writer} =
        SessionWriter.start_link(%{
          identifier: identifier,
          session_id: session_id,
          base_url: "http://127.0.0.1:1"
        })

      on_exit(fn ->
        if Process.alive?(writer) do
          try do
            GenServer.stop(writer)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      assert :ok = SessionWriter.await_replay(writer)

      send(writer, {:transcript_event, %{role: :assistant, body: "one ", timestamp: DateTime.utc_now()}})
      send(writer, {:transcript_event, %{role: :assistant, body: "two", timestamp: DateTime.utc_now()}})
      send(writer, {:transcript_event, %{role: :command, body: "$ mix test", timestamp: DateTime.utc_now()}})

      Process.sleep(300)

      assert [{message_id, message_data}] = assistant_messages(db_path, session_id)
      assert message_data["finish"] == "tool-calls"

      assert [
               %{"type" => "step-start"},
               %{"type" => "text", "text" => "one two"},
               %{"type" => "tool", "state" => %{"input" => %{"command" => "$ mix test"}}},
               %{"type" => "step-finish", "reason" => "tool-calls"}
             ] = parts(db_path, message_id)
    end
  end

  defmodule NeverReplies do
    use GenServer
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def handle_call(_, _from, state), do: {:noreply, state}
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

  defp assistant_messages(db_path, session_id) do
    {:ok, conn} = Basic.open(db_path)

    {:ok, rows, _} =
      Basic.rows(
        Basic.exec(conn, "SELECT id, data FROM message WHERE session_id = ? ORDER BY rowid", [
          session_id
        ])
      )

    Basic.close(conn)

    rows
    |> Enum.map(fn [id, json] -> {id, Jason.decode!(json)} end)
    |> Enum.filter(fn {_id, data} -> data["role"] == "assistant" end)
  end

  defp parts(db_path, message_id) do
    {:ok, conn} = Basic.open(db_path)

    {:ok, rows, _} =
      Basic.rows(Basic.exec(conn, "SELECT data FROM part WHERE message_id = ? ORDER BY rowid", [message_id]))

    Basic.close(conn)

    Enum.map(rows, fn [json] -> Jason.decode!(json) end)
  end
end

defmodule Aiur.Opencode.SessionWriterTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{Db, SessionWriter}
  alias Exqlite.Basic

  describe "await_replay/2" do
    test "returns {:error, :no_writer} when called against a dead pid" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(pid)

      assert SessionWriter.await_replay(pid, 100) == {:error, :no_writer}
    end

    test "returns {:error, :timeout} when GenServer does not reply in time" do
      {:ok, dummy} = GenServer.start_link(Aiur.Opencode.SessionWriterTest.NeverReplies, nil)

      assert SessionWriter.await_replay(dummy, 50) == {:error, :timeout}
      GenServer.stop(dummy)
    end
  end

  describe "turn grouping (U1)" do
    setup [:db_fixture]

    test "first transcript event with a turn_id opens a message; second appends to it", %{
      session_id: session_id
    } do
      state = build_state(session_id)
      turn_id = "turn_abc"

      {:noreply, state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:command, "ls", turn_id: turn_id)},
          state
        )

      assert %{turns: turns} = state
      assert %{message_id: msg_id_1} = turns[turn_id]

      {:noreply, state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:assistant, "Found three files.", turn_id: turn_id)},
          state
        )

      assert %{message_id: ^msg_id_1} = state.turns[turn_id]

      # One message in the DB, with step-start + two body parts (no step-finish yet).
      assert count_messages(session_id) == 1
      types = part_types(session_id, msg_id_1)
      assert "step-start" in types
      refute "step-finish" in types
      # Body parts: a tool (from :command) + a text (from :assistant)
      assert Enum.count(types, &(&1 == "tool")) == 1
      assert Enum.count(types, &(&1 == "text")) == 1
    end

    test ":turn_event with :turn_completed appends step-finish and drops the turn from state", %{
      session_id: session_id
    } do
      state = build_state(session_id)
      turn_id = "turn_xyz"

      {:noreply, state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:command, "echo hi", turn_id: turn_id)},
          state
        )

      msg_id = state.turns[turn_id].message_id

      {:noreply, state} =
        SessionWriter.handle_info(
          {:turn_event, "test-id", :turn_completed, %{turn_id: turn_id}},
          state
        )

      assert state.turns == %{}

      types = part_types(session_id, msg_id)
      assert "step-finish" in types
    end

    test ":turn_event with :turn_failed maps to step-finish reason 'error'", %{session_id: session_id} do
      state = build_state(session_id)
      turn_id = "turn_fail"

      {:noreply, state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:assistant, "starting", turn_id: turn_id)},
          state
        )

      msg_id = state.turns[turn_id].message_id

      {:noreply, _state} =
        SessionWriter.handle_info(
          {:turn_event, "test-id", :turn_failed, %{turn_id: turn_id}},
          state
        )

      assert step_finish_reason(session_id, msg_id) == "error"
    end

    test ":turn_event for an unseen turn_id is a no-op (idempotent finalize)", %{
      session_id: session_id
    } do
      state = build_state(session_id)

      {:noreply, new_state} =
        SessionWriter.handle_info(
          {:turn_event, "test-id", :turn_completed, %{turn_id: "never_opened"}},
          state
        )

      assert new_state.turns == %{}
      assert count_messages(session_id) == 0
    end

    test "transcript event with turn_id: nil writes a standalone message and leaves turns untouched",
         %{session_id: session_id} do
      state = build_state(session_id)

      {:noreply, state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:assistant, "hello", turn_id: nil)},
          state
        )

      assert state.turns == %{}
      assert count_messages(session_id) == 1
    end

    test "opencode-origin :user events are dropped without writes", %{session_id: session_id} do
      # Locally-typed input is echoed by opencode itself; writing it again
      # would double-render the operator's own message.
      state = build_state(session_id)

      {:noreply, new_state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:user, "operator typed this", turn_id: "t1")},
          state
        )

      assert new_state == state
      assert count_messages(session_id) == 0
    end

    test "a remote-origin :user event is written as a genuine user-role message", %{
      session_id: session_id
    } do
      # Remote Control messages are never typed into opencode, so opencode
      # never echoes them. SessionWriter persists them as a real user-role
      # row so they render as a user turn — not as assistant speech.
      state = build_state(session_id)

      {:noreply, _state} =
        SessionWriter.handle_info(
          {:transcript_event, remote_user_event("hi from claude remote control")},
          state
        )

      assert count_messages(session_id) == 1
      assert message_role(session_id) == "user"

      [text_part] = parts_of_type(session_id, "text")
      assert Jason.decode!(text_part)["text"] == "hi from claude remote control"
    end

    test ":command event with payload writes clean bash tool part shape (U3)", %{
      session_id: session_id
    } do
      state = build_state(session_id)

      event = %{
        role: :command,
        body: "git status --short",
        timestamp: DateTime.utc_now(),
        msg_id: nil,
        sequence: 1,
        turn_id: nil,
        payload: %{
          command: "git status --short",
          output: "?? test-sandbox/\n",
          title: "git status --short",
          workdir: "/home/dev/repo",
          exit_code: 0
        }
      }

      {:noreply, _state} = SessionWriter.handle_info({:transcript_event, event}, state)

      [tool_part] = parts_of_type(session_id, "tool")
      decoded = Jason.decode!(tool_part)

      assert decoded["tool"] == "bash"
      assert decoded["state"]["input"]["command"] == "git status --short"
      refute String.starts_with?(decoded["state"]["input"]["command"], "$ ")
      assert decoded["state"]["input"]["workdir"] == "/home/dev/repo"
      assert decoded["state"]["output"] == "?? test-sandbox/\n"
      assert decoded["state"]["title"] == "git status --short"
    end

    test ":tool role events render as tool parts with payload-supplied tool name (U2)",
         %{session_id: session_id} do
      state = build_state(session_id)

      event = %{
        role: :tool,
        body: "emit_alert · attention.review-ready",
        timestamp: DateTime.utc_now(),
        msg_id: nil,
        sequence: 1,
        turn_id: nil,
        payload: %{
          tool: "emit_alert",
          input: %{"name" => "attention.review-ready", "message" => "ready"},
          output: "ok=true",
          title: "emit_alert · attention.review-ready"
        }
      }

      {:noreply, _state} = SessionWriter.handle_info({:transcript_event, event}, state)

      [tool_part] = parts_of_type(session_id, "tool")
      decoded = Jason.decode!(tool_part)

      assert decoded["tool"] == "emit_alert"
      assert decoded["state"]["title"] == "emit_alert · attention.review-ready"
      assert get_in(decoded, ["state", "input", "name"]) == "attention.review-ready"
    end

    test ":reasoning role events render as reasoning parts (U2)", %{session_id: session_id} do
      state = build_state(session_id)

      event = %{
        role: :reasoning,
        body: "Considering whether to use Map.new/1 vs Enum.into/2.",
        timestamp: DateTime.utc_now(),
        msg_id: nil,
        sequence: 1,
        turn_id: nil,
        payload: nil
      }

      {:noreply, _state} = SessionWriter.handle_info({:transcript_event, event}, state)

      [reasoning_part] = parts_of_type(session_id, "reasoning")
      decoded = Jason.decode!(reasoning_part)

      assert decoded["text"] == "Considering whether to use Map.new/1 vs Enum.into/2."
    end

    test "two interleaved turn_ids open two distinct messages", %{session_id: session_id} do
      state = build_state(session_id)

      {:noreply, state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:command, "a", turn_id: "t1")},
          state
        )

      {:noreply, state} =
        SessionWriter.handle_info(
          {:transcript_event, transcript_event(:command, "b", turn_id: "t2")},
          state
        )

      m1 = state.turns["t1"].message_id
      m2 = state.turns["t2"].message_id
      refute m1 == m2

      assert count_messages(session_id) == 2
    end
  end

  describe "FOREIGN KEY threshold backoff" do
    test "first FK violation bumps counter from 0 → 1, does not stop" do
      state = %SessionWriter{
        identifier: "fk-test-1",
        session_id: "ses_fk_1",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 0
      }

      reason = %Exqlite.Error{message: "FOREIGN KEY constraint failed"}

      assert {:noreply, %SessionWriter{consecutive_fk_failures: 1}} =
               SessionWriter.handle_write_failure_for_test(state, reason)
    end

    test "5th consecutive FK violation stops the writer with :normal" do
      state = %SessionWriter{
        identifier: "fk-test-2",
        session_id: "ses_fk_2",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 4
      }

      reason = %Exqlite.Error{message: "FOREIGN KEY constraint failed"}

      assert {:stop, :normal, %SessionWriter{consecutive_fk_failures: 5}} =
               SessionWriter.handle_write_failure_for_test(state, reason)
    end

    test "non-FK error leaves the counter unchanged and does not stop" do
      state = %SessionWriter{
        identifier: "fk-test-3",
        session_id: "ses_fk_3",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 3
      }

      assert {:noreply, %SessionWriter{consecutive_fk_failures: 3}} =
               SessionWriter.handle_write_failure_for_test(state, :network_timeout)
    end

    test "reset_fk_failures zeroes a non-zero counter" do
      state = %SessionWriter{
        identifier: "fk-test-4",
        session_id: "ses_fk_4",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 3
      }

      assert %SessionWriter{consecutive_fk_failures: 0} =
               SessionWriter.reset_fk_failures_for_test(state)
    end

    test "reset is a no-op on a counter already at 0" do
      state = %SessionWriter{
        identifier: "fk-test-5",
        session_id: "ses_fk_5",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 0
      }

      # Same struct identity preserved when no work needed.
      assert state == SessionWriter.reset_fk_failures_for_test(state)
    end

    test "interleaved FK / success / FK pattern correctly resets between bursts" do
      state = %SessionWriter{
        identifier: "fk-test-6",
        session_id: "ses_fk_6",
        base_url: "http://127.0.0.1:1",
        consecutive_fk_failures: 4
      }

      reason = %Exqlite.Error{message: "FOREIGN KEY constraint failed"}

      # Success resets.
      state = SessionWriter.reset_fk_failures_for_test(state)
      assert state.consecutive_fk_failures == 0

      # 4 more FKs do not trip threshold.
      state =
        Enum.reduce(1..4, state, fn _, acc ->
          {:noreply, next} = SessionWriter.handle_write_failure_for_test(acc, reason)
          next
        end)

      assert state.consecutive_fk_failures == 4

      # Another success resets again — a single isolated FK after this
      # must NOT trip the threshold even though we had 4 FKs earlier.
      state = SessionWriter.reset_fk_failures_for_test(state)

      assert {:noreply, %SessionWriter{consecutive_fk_failures: 1}} =
               SessionWriter.handle_write_failure_for_test(state, reason)
    end
  end

  defmodule NeverReplies do
    use GenServer
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def handle_call(_, _from, state), do: {:noreply, state}
  end

  # ----------------------------------------------------------------- helpers

  defp db_fixture(_ctx) do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "aiur-session-writer-test-#{System.unique_integer([:positive])}.db"
      )

    initialize_schema!(db_path)
    Application.put_env(:aiur, :opencode_db_path_override, db_path)

    session_id = "ses_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:aiur, :opencode_db_path_override)
      File.rm_rf(db_path)
      File.rm_rf(db_path <> "-shm")
      File.rm_rf(db_path <> "-wal")
    end)

    %{db_path: db_path, session_id: session_id}
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

  defp build_state(session_id) do
    %SessionWriter{
      identifier: "test-id",
      session_id: session_id,
      # Unreachable base_url — nudge_tui will fail and log a warning,
      # but handle_info returns successfully so we can still assert
      # on the DB writes that did land. Tests run in <1 s anyway.
      base_url: "http://127.0.0.1:1",
      root_msg_id: "msg_test_root",
      turns: %{}
    }
  end

  defp transcript_event(role, body, opts) do
    %{
      role: role,
      body: body,
      timestamp: DateTime.utc_now(),
      msg_id: nil,
      sequence: :erlang.unique_integer([:positive, :monotonic]),
      turn_id: Keyword.get(opts, :turn_id)
    }
  end

  defp remote_user_event(body) do
    %{
      role: :user,
      body: body,
      timestamp: DateTime.utc_now(),
      msg_id: nil,
      sequence: :erlang.unique_integer([:positive, :monotonic]),
      turn_id: nil,
      payload: %{origin: :remote}
    }
  end

  defp message_role(session_id) do
    {:ok, conn} = Basic.open(Db.path())

    {:ok, rows, _} =
      Basic.exec(conn, "SELECT data FROM message WHERE session_id = '#{session_id}'")
      |> Basic.rows()

    Basic.close(conn)
    rows |> List.first() |> List.first() |> Jason.decode!() |> Map.get("role")
  end

  defp count_messages(session_id) do
    {:ok, conn} = Basic.open(Db.path())
    {:ok, rows, _} = Basic.exec(conn, "SELECT COUNT(*) FROM message WHERE session_id = '#{session_id}'") |> Basic.rows()
    Basic.close(conn)
    rows |> List.first() |> List.first()
  end

  defp part_types(session_id, message_id) do
    {:ok, conn} = Basic.open(Db.path())

    {:ok, rows, _} =
      Basic.exec(
        conn,
        "SELECT data FROM part WHERE session_id = '#{session_id}' AND message_id = '#{message_id}'"
      )
      |> Basic.rows()

    Basic.close(conn)
    Enum.map(rows, fn [data] -> Jason.decode!(data)["type"] end)
  end

  defp parts_of_type(session_id, type) do
    {:ok, conn} = Basic.open(Db.path())

    {:ok, rows, _} =
      Basic.exec(
        conn,
        "SELECT data FROM part WHERE session_id = '#{session_id}'"
      )
      |> Basic.rows()

    Basic.close(conn)

    Enum.flat_map(rows, fn [data] ->
      decoded = Jason.decode!(data)
      if decoded["type"] == type, do: [data], else: []
    end)
  end

  defp step_finish_reason(session_id, message_id) do
    {:ok, conn} = Basic.open(Db.path())

    {:ok, rows, _} =
      Basic.exec(
        conn,
        "SELECT data FROM part WHERE session_id = '#{session_id}' AND message_id = '#{message_id}'"
      )
      |> Basic.rows()

    Basic.close(conn)

    Enum.find_value(rows, fn [data] ->
      decoded = Jason.decode!(data)
      if decoded["type"] == "step-finish", do: decoded["reason"]
    end)
  end
end

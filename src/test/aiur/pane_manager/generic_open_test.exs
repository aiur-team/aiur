defmodule Aiur.PaneManager.GenericOpenTest do
  use ExUnit.Case, async: false

  alias Aiur.PaneManager.{GenericOpen, State}
  alias Aiur.Tmux

  setup do
    previous_cookie = System.get_env("AIUR_ERLANG_COOKIE")

    test_pid = self()
    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [transport: {:mock, test_pid}, name: tmux_name, session: "test"]},
        id: tmux_name
      )

    on_exit(fn ->
      if previous_cookie, do: System.put_env("AIUR_ERLANG_COOKIE", previous_cookie), else: System.delete_env("AIUR_ERLANG_COOKIE")
    end)

    state = %State{
      tmux: tmux_name,
      agent_list_pane: "%1",
      window_target: "test:0",
      slot_panes: State.empty_slot_panes(5)
    }

    %{tmux: tmux_name, state: state}
  end

  defp respond(tmux, body \\ "") do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}\n%end 1 1 0\n"})
  end

  defp drain_focus_title_and_layout(tmux, pane_id, identifier) do
    assert_receive {:tmux_mock_out, "select-pane -t " <> ^pane_id}, 500
    respond(tmux)
    assert_receive {:tmux_mock_out, "select-pane -t " <> ^pane_id <> " -T " <> ^identifier}, 500
    respond(tmux)
    assert_receive {:tmux_mock_out, "display-message -p -t %1 " <> _}, 500
    respond(tmux, "80x24")
    assert_receive {:tmux_mock_out, "select-layout -t test:0 " <> _}, 500
    respond(tmux)
  end

  describe "wrap_with_unique_node/2" do
    test "produces env ERL_AFLAGS with name, proto_dist, and inet_dist flags" do
      result = GenericOpen.wrap_with_unique_node("mycommand", "issue-1")

      assert result =~ ~r/^env ERL_AFLAGS="/
      assert result =~ ~r/-name pane-issue-1-[A-Za-z0-9]+@127\.0\.0\.1/
      assert result =~ "-proto_dist inet_tcp"
      assert result =~ "-kernel inet_dist_use_interface {127,0,0,1}"
      assert String.ends_with?(result, "\" mycommand")
    end

    test "sanitizes non-alphanumeric/underscore/dash characters to dash" do
      result = GenericOpen.wrap_with_unique_node("cmd", "issue 1/foo.bar")

      assert result =~ ~r/-name pane-issue-1-foo-bar-[A-Za-z0-9]+@127\.0\.0\.1/
    end

    @tag :capture_log
    test "with AIUR_ERLANG_COOKIE env var includes -setcookie <cookie>" do
      System.put_env("AIUR_ERLANG_COOKIE", "testcookie123")

      result = GenericOpen.wrap_with_unique_node("cmd", "issue-1")
      assert result =~ "-setcookie testcookie123"
    end

    @tag :capture_log
    test "without AIUR_ERLANG_COOKIE env var does not use the env cookie" do
      System.delete_env("AIUR_ERLANG_COOKIE")

      result = GenericOpen.wrap_with_unique_node("cmd", "issue-1")
      # No env-based cookie should appear (file cookie may still appear)
      refute result =~ "-setcookie testcookie123"
    end
  end

  describe "read_erlang_cookie/0" do
    @tag :capture_log
    test "returns env cookie when AIUR_ERLANG_COOKIE is set" do
      System.put_env("AIUR_ERLANG_COOKIE", "mycookie")

      assert GenericOpen.read_erlang_cookie() == "mycookie"
    end

    test "returns a binary or nil when AIUR_ERLANG_COOKIE is not set" do
      System.delete_env("AIUR_ERLANG_COOKIE")
      result = GenericOpen.read_erlang_cookie()
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "open_generic_pane/4" do
    test "creates a pane in the next empty slot", %{tmux: tmux, state: state} do
      task = Task.async(fn -> GenericOpen.open_generic_pane(state, "issue-1", "echo hello", nil) end)

      assert_receive {:tmux_mock_out, "split-window " <> command}, 500
      assert command =~ "echo hello"
      respond(tmux, "%10")
      drain_focus_title_and_layout(tmux, "%10", "issue-1")

      assert {:reply, {:ok, "%10"}, new_state} = Task.await(task)
      assert new_state.identifier_to_pane == %{"issue-1" => "%10"}
      assert new_state.cycle_index == 1
    end

    test "respawns the occupied slot instead of splitting another pane", %{tmux: tmux, state: state} do
      state = State.record_slot_pane(state, 1, "%10", "old")
      task = Task.async(fn -> GenericOpen.open_generic_pane(state, "issue-2", "echo replacement", nil) end)

      assert_receive {:tmux_mock_out, "respawn-pane -k -t %10 " <> command}, 500
      assert command =~ "echo replacement"
      respond(tmux)
      assert_receive {:tmux_mock_out, "select-pane -t %10 -T issue-2"}, 500
      respond(tmux)
      assert_receive {:tmux_mock_out, "display-message -p -t %1 " <> _}, 500
      respond(tmux, "80x24")
      assert_receive {:tmux_mock_out, "select-layout -t test:0 " <> _}, 500
      respond(tmux)

      assert {:reply, {:ok, "%10"}, new_state} = Task.await(task)
      assert new_state.identifier_to_pane == %{"issue-2" => "%10"}
      refute Map.has_key?(new_state.identifier_to_pane, "old")
    end

    test "returns tmux split errors without changing state", %{tmux: tmux, state: state} do
      task = Task.async(fn -> GenericOpen.open_generic_pane(state, "issue-3", "echo nope", nil) end)

      assert_receive {:tmux_mock_out, "split-window " <> _}, 500

      send(
        GenServer.whereis(tmux),
        {:tmux_mock_data, "%begin 1 1 0\nno space for pane\n%error 1 1 0\n"}
      )

      assert {:reply, {:error, _}, ^state} = Task.await(task)
    end
  end
end

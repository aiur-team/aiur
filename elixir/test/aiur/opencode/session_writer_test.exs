defmodule Aiur.Opencode.SessionWriterTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.SessionWriter

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

  defmodule NeverReplies do
    use GenServer
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def handle_call(_, _from, state), do: {:noreply, state}
  end
end

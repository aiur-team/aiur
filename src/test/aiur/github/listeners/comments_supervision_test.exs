defmodule Aiur.GitHub.Listeners.CommentsSupervisionTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.{Comments, Firehose}

  for {listener, sibling} <- [{Comments, Firehose}, {Firehose, Comments}] do
    test "a #{inspect(listener)} crash restarts only that listener" do
      {listener, sibling} = {unquote(listener), unquote(sibling)}
      root_children = root_children()
      previous_sibling = Process.whereis(sibling)
      previous = Process.whereis(listener)
      ref = Process.monitor(previous)
      Process.exit(previous, :kill)
      receive_barrier({:DOWN, ^ref, :process, ^previous, :killed})
      # The supervisor finishes the restart before answering this call.
      Supervisor.which_children(Listeners)
      assert is_pid(Process.whereis(listener))
      assert Process.whereis(listener) != previous
      assert Process.whereis(sibling) == previous_sibling
      assert root_children() == root_children
      assert :ok = Listeners.reset()
    end
  end

  defp root_children, do: for({id, pid, _type, _modules} <- Supervisor.which_children(Aiur.Supervisor), do: {id, pid})
end

defmodule Aiur.AsksCLITest do
  use ExUnit.Case, async: false

  alias Aiur.{Asks, AsksCLI}

  setup do
    # Keep repo state in the suite root, which lives until after_suite; a
    # late writer must not race deletion of a per-test state root.
    previous_root = Application.get_env(:aiur, :repo_base_root)
    slug = "#{System.pid()}-#{System.unique_integer([:positive])}"
    state_root = Path.join(Application.fetch_env!(:aiur, :test_run_root), "asks-cli-#{slug}")
    Application.put_env(:aiur, :repo_base_root, state_root)
    on_exit(fn -> restore_repo_root(previous_root) end)

    {:ok, repo: "owner/asks-cli-#{slug}"}
  end

  defp restore_repo_root(nil), do: Application.delete_env(:aiur, :repo_base_root)
  defp restore_repo_root(root), do: Application.put_env(:aiur, :repo_base_root, root)

  test "create raises a free-text Executor Command and keeps ask defaults", %{repo: repo} do
    command = {:create, %{title: "Approve release", body: "Release context", urgency: "normal", blocking: false}}
    puts = fn line -> send(self(), {:output, IO.iodata_to_binary(line)}) end

    rpc = fn :request, params ->
      assert params[:question] == "Approve release"
      assert params[:long_context_markdown] == "Release context"
      assert params[:urgency] == "normal"
      assert params[:blocking] == false
      assert params[:options] == []
      params[:result_fun].(%{decision_id: "dec_0123456789abcdef"}, :accepted, "source", false)
      0
    end

    assert 0 == AsksCLI.run(command, puts, fn -> repo end, rpc)
    assert_received {:output, "Created dec_0123456789abcdef."}
    assert_received {:output, "Deprecated: use aiur command request; Command IDs now use the dec_ prefix."}
    assert {:ok, []} = Asks.all(repo)
  end

  test "Command done routes to executor withdrawal", %{repo: repo} do
    rpc = fn :moot, params ->
      assert params[:decision_id] == "dec_0123456789abcdef"
      assert params[:reason_class] == "executor_withdrew"
      assert params[:reason] == "No longer needed"
      0
    end

    assert 0 == AsksCLI.run({:done, %{id: "dec_0123456789abcdef", note: "No longer needed"}}, &IO.puts/1, fn -> repo end, rpc)
  end

  test "legacy done resolves locally without RPC", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "Old request", urgency: "normal", blocking: false})
    assert 0 == AsksCLI.run({:done, %{id: ask["id"], note: "Finished"}}, fn _ -> :ok end, fn -> repo end, fn _, _ -> flunk("legacy resolve called RPC") end)
    assert {:ok, [%{"status" => "done", "note" => "Finished"}]} = Asks.all(repo)
  end

  test "renders completed asks only under all with the resolution note", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "Refresh credentials", urgency: "normal", blocking: false})
    assert {:ok, _} = Asks.resolve(repo, ask["id"], "done by operator")
    lines = Agent.start_link(fn -> [] end) |> elem(1)
    puts = fn line -> Agent.update(lines, &[IO.iodata_to_binary(line) | &1]) end

    assert 0 == AsksCLI.run({:list, %{status: :open, json: false}}, puts, fn -> repo end)
    assert Agent.get(lines, &Enum.reverse/1) == ["Legacy asks only. View Executor Commands with aiur commands."]

    assert 0 == AsksCLI.run({:list, %{status: :all, json: false}}, puts, fn -> repo end)
    [_first_pointer, rendered, _last_pointer] = Agent.get(lines, &Enum.reverse/1)
    assert rendered =~ "[DONE]"
    assert rendered =~ "Note: done by operator"
  end
end

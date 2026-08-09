defmodule Aiur.AsksCLITest do
  use ExUnit.Case, async: false

  alias Aiur.{Asks, AsksCLI}

  setup do
    root = Path.join(System.tmp_dir!(), "aiur_asks_cli_#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, root)

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      File.rm_rf!(root)
    end)

    {:ok, repo: "owner/repo"}
  end

  test "writes and JSON-round-trips an open ask", %{repo: repo} do
    lines = Agent.start_link(fn -> [] end) |> elem(1)
    puts = fn line -> Agent.update(lines, &[IO.iodata_to_binary(line) | &1]) end
    command = {:create, %{title: "Enable CI readiness", body: "gh auth refresh -s workflow", urgency: "high", blocking: true}}

    assert 0 == AsksCLI.run(command, puts, fn -> repo end)
    [created] = Agent.get(lines, &Enum.reverse/1)
    assert created =~ "Created ask_"
    assert created =~ "BLOCKING"

    Agent.update(lines, fn _ -> [] end)
    assert 0 == AsksCLI.run({:list, %{status: :open, json: true}}, puts, fn -> repo end)
    [encoded] = Agent.get(lines, &Enum.reverse/1)
    assert [%{"title" => "Enable CI readiness", "body" => "gh auth refresh -s workflow", "blocking" => true}] = Jason.decode!(encoded)
  end

  test "renders completed asks only under all with the resolution note", %{repo: repo} do
    assert {:ok, ask} = Asks.create(repo, %{title: "Refresh credentials", urgency: "normal", blocking: false})
    assert {:ok, _} = Asks.resolve(repo, ask["id"], "done by operator")
    lines = Agent.start_link(fn -> [] end) |> elem(1)
    puts = fn line -> Agent.update(lines, &[IO.iodata_to_binary(line) | &1]) end

    assert 0 == AsksCLI.run({:list, %{status: :open, json: false}}, puts, fn -> repo end)
    assert Agent.get(lines, &Enum.reverse/1) == []

    assert 0 == AsksCLI.run({:list, %{status: :all, json: false}}, puts, fn -> repo end)
    [rendered] = Agent.get(lines, &Enum.reverse/1)
    assert rendered =~ "[DONE]"
    assert rendered =~ "Note: done by operator"
  end
end

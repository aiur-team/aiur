defmodule Aiur.OpenAICompat.ToolsTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.{CommandRunner, ToolCallParser, Tools}

  test "tool specifications match each OpenAI-compatible transport" do
    assert %{"type" => "function", "function" => %{"name" => "read_file"}} = hd(Tools.specs(:chat_completions))
    assert %{"type" => "function", "name" => "read_file", "parameters" => %{}} = hd(Tools.specs(:responses))
  end

  test "plain-text fallback accepts only explicit structured envelopes" do
    assert ToolCallParser.parse(~s(I think {"name":"read_file","arguments":{"path":"x"}})) == []

    assert [%{id: "fallback-1", name: "read_file", arguments: %{"path" => "x"}}] =
             ToolCallParser.parse(~s(<tool_call>{"name":"read_file","arguments":{"path":"x"}}</tool_call>))
  end

  test "workspace tools reject path traversal" do
    context = %{workspace: System.tmp_dir!(), tool_executor: nil}
    assert %{"success" => false, "output" => "outside_workspace"} = Tools.execute("read_file", %{"path" => "../secret"}, context, [])
  end

  test "workspace file tools reject symlinks that escape the workspace" do
    workspace = Path.join(System.tmp_dir!(), "aiur-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    File.ln_s!(System.tmp_dir!(), Path.join(workspace, "outside"))
    on_exit(fn -> File.rm_rf!(workspace) end)

    context = %{workspace: workspace, tool_executor: nil}

    assert %{"success" => false, "output" => "outside_workspace"} =
             Tools.execute("read_file", %{"path" => "outside/secret"}, context, [])

    assert %{"success" => false, "output" => "outside_workspace"} =
             Tools.execute("list_files", %{"glob" => "outside/*"}, context, [])
  end

  test "tool validation returns matchable errors" do
    assert {:error, {:missing_required_arguments, ["path"]}} =
             Tools.decode_and_validate("read_file", %{})

    assert {:error, {:invalid_argument_types, ["path"]}} =
             Tools.decode_and_validate("read_file", %{"path" => 42})

    assert {:error, {:unsupported_tool, "missing"}} =
             Tools.decode_and_validate("missing", %{})
  end

  test "workspace file tools write, replace, and list files" do
    workspace = Path.join(System.tmp_dir!(), "aiur-tools-edit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    context = %{workspace: workspace, tool_executor: nil}

    assert %{"success" => true} = Tools.execute("write_file", %{"path" => "nested/note.txt", "content" => "before"}, context, [])
    assert File.read!(Path.join(workspace, "nested/note.txt")) == "before"

    assert %{"success" => true} =
             Tools.execute("replace_in_file", %{"path" => "nested/note.txt", "old_text" => "before", "new_text" => "after"}, context, [])

    assert File.read!(Path.join(workspace, "nested/note.txt")) == "after"
    assert %{"success" => true, "output" => files} = Tools.execute("list_files", %{"glob" => "nested/*.txt"}, context, [])
    assert files == "nested/note.txt"
  end

  test "workspace file listing supports recursive, grouped, and character-class globs" do
    workspace = Path.join(System.tmp_dir!(), "aiur-tools-glob-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "nested/deep"))
    File.write!(Path.join(workspace, "root.ex"), "")
    File.write!(Path.join(workspace, "nested/one.exs"), "")
    File.write!(Path.join(workspace, "nested/deep/two.txt"), "")
    on_exit(fn -> File.rm_rf!(workspace) end)
    context = %{workspace: workspace, tool_executor: nil}

    assert %{"success" => true, "output" => recursive} =
             Tools.execute("list_files", %{"glob" => "**/*.{ex,exs}"}, context, [])

    assert String.split(recursive, "\n") == ["nested/one.exs", "root.ex"]

    assert %{"success" => true, "output" => class_match} =
             Tools.execute("list_files", %{"glob" => "nested/deep/tw[!a].txt"}, context, [])

    assert class_match == "nested/deep/two.txt"
  end

  test "workspace file listing stops at its response limit" do
    workspace = Path.join(System.tmp_dir!(), "aiur-tools-limit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    for index <- 1..2_050 do
      File.write!(Path.join(workspace, "#{index}.txt"), "")
    end

    on_exit(fn -> File.rm_rf!(workspace) end)
    context = %{workspace: workspace, tool_executor: nil}

    assert %{"success" => true, "output" => output} =
             Tools.execute("list_files", %{"glob" => "**/*"}, context, [])

    assert output |> String.split("\n") |> length() == 2_000
  end

  test "workspace replacement requires exactly one match" do
    workspace = Path.join(System.tmp_dir!(), "aiur-tools-replace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "note.txt"), "same same")
    on_exit(fn -> File.rm_rf!(workspace) end)
    context = %{workspace: workspace, tool_executor: nil}

    assert %{"success" => false, "output" => "old_text_not_unique"} =
             Tools.execute("replace_in_file", %{"path" => "note.txt", "old_text" => "same", "new_text" => "new"}, context, [])

    assert %{"success" => false, "output" => "old_text_not_found"} =
             Tools.execute("replace_in_file", %{"path" => "note.txt", "old_text" => "missing", "new_text" => "new"}, context, [])
  end

  test "command execution fails closed without a sandbox" do
    assert %{"success" => false, "output" => message} =
             CommandRunner.run(System.tmp_dir!(), "echo unsafe", sandbox_executable: nil)

    assert message =~ "sandbox unavailable"
  end

  test "a crashing sandbox process becomes a failed tool result" do
    assert %{"success" => false, "output" => "command runner failed"} =
             CommandRunner.run(System.tmp_dir!(), "echo safe",
               sandbox_executable: "/usr/bin/bwrap",
               system_cmd: fn _executable, _args, _opts -> raise "launch failed" end
             )
  end

  test "command execution clears the host environment and mounts only explicit roots" do
    parent = self()

    runner = fn executable, args, opts ->
      send(parent, {:command, executable, args, opts})
      {"ok", 0}
    end

    assert %{"success" => true} =
             CommandRunner.run(System.tmp_dir!(), "echo safe",
               sandbox_executable: "/usr/bin/bwrap",
               system_cmd: runner
             )

    assert_receive {:command, "/usr/bin/bwrap", args, [stderr_to_stdout: true]}

    assert "--clearenv" in args
    refute ["--ro-bind", "/", "/"] in Enum.chunk_every(args, 3, 1, :discard)
    assert ["--ro-bind", "/usr", "/usr"] in Enum.chunk_every(args, 3, 1, :discard)

    for credential <- ~w(DEEPSEEK_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY) do
      refute credential in args
    end

    assert ["--setenv", "HOME", System.tmp_dir!()] in Enum.chunk_every(args, 3, 1, :discard)

    for path <- ~w(/bin /lib /lib64) do
      case File.read_link(path) do
        {:ok, target} -> assert ["--symlink", target, path] in Enum.chunk_every(args, 3, 1, :discard)
        {:error, _reason} -> if File.dir?(path), do: assert(["--ro-bind", path, path] in Enum.chunk_every(args, 3, 1, :discard))
      end
    end

    for identity <- ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL) do
      assert Enum.any?(Enum.chunk_every(args, 3, 1, :discard), &match?(["--setenv", ^identity, _value], &1))
    end
  end

  test "real command sandbox cannot read a host sibling" do
    case System.find_executable("bwrap") do
      nil ->
        :ok

      executable ->
        root = Path.join(System.tmp_dir!(), "aiur-command-isolation-#{System.unique_integer([:positive])}")
        workspace = Path.join(root, "workspace")
        File.mkdir_p!(workspace)
        File.write!(Path.join(root, "host-secret"), "not visible")
        on_exit(fn -> File.rm_rf!(root) end)

        assert %{"success" => true, "output" => "sandboxed\n"} =
                 CommandRunner.run(workspace, "test ! -r ../host-secret && printf 'sandboxed\\n'", sandbox_executable: executable)
    end
  end

  test "dynamic tools use the runner-bound executor" do
    context = %{workspace: System.tmp_dir!(), tool_executor: fn name, args -> %{"success" => true, "output" => {name, args}} end}

    assert %{"success" => true, "output" => {"emit_alert", %{"name" => "phase.work.start"}}} =
             Tools.execute("emit_alert", %{"name" => "phase.work.start"}, context, [])
  end
end

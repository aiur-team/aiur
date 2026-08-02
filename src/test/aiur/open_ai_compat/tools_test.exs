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

    assert %{"success" => false, "output" => "symlink_path"} =
             Tools.execute("read_file", %{"path" => "outside/secret"}, context, [])

    assert %{"success" => false, "output" => "symlink_path"} =
             Tools.execute("list_files", %{"glob" => "outside/*"}, context, [])
  end

  test "command execution fails closed without a sandbox" do
    assert %{"success" => false, "output" => message} =
             CommandRunner.run(System.tmp_dir!(), "echo unsafe", sandbox_executable: nil)

    assert message =~ "sandbox unavailable"
  end

  test "command execution removes provider credentials from the sandbox" do
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

    for credential <- ~w(DEEPSEEK_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY) do
      assert ["--unsetenv", credential] in Enum.chunk_every(args, 2, 1, :discard)
    end
  end

  test "dynamic tools use the runner-bound executor" do
    context = %{workspace: System.tmp_dir!(), tool_executor: fn name, args -> %{"success" => true, "output" => {name, args}} end}

    assert %{"success" => true, "output" => {"emit_alert", %{"name" => "phase.work.start"}}} =
             Tools.execute("emit_alert", %{"name" => "phase.work.start"}, context, [])
  end
end

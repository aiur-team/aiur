defmodule Aiur.OpenAICompat.CommandRunnerSandboxTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Schema.CommandSandbox
  alias Aiur.OpenAICompat.CommandRunner
  alias Aiur.TestSupport.RuntimeChildren

  setup do
    :ok = RuntimeChildren.ensure_aiur_supervisor_running()
    root = Aiur.TestSupport.tmp_root!("aiur-command-sandbox")
    for dir <- ~w(workspace ro rw tools elsewhere), do: File.mkdir_p!(Path.join(root, dir))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, root: root, workspace: Path.join(root, "workspace")}
  end

  defp bwrap_args(workspace, sandbox) do
    parent = self()
    runner = fn _exe, args, _opts -> send(parent, {:args, args}) && {"ok", 0} end
    CommandRunner.run(workspace, "true", sandbox_executable: "/usr/bin/bwrap", system_cmd: runner, command_sandbox: sandbox)
    assert_receive {:args, args}, 1000
    args
  end

  defp triples(args), do: Enum.chunk_every(args, 3, 1, :discard)

  defp sandbox_path(args) do
    args
    |> triples()
    |> Enum.find_value(fn
      ["--setenv", "PATH", path] -> path
      _ -> nil
    end)
  end

  test "configured binds become ro-bind and bind pairs", %{root: root, workspace: ws} do
    ro = Path.join(root, "ro")
    rw = Path.join(root, "rw")
    args = bwrap_args(ws, %{"read_only_binds" => [ro, "/nonexistent-aiur-7783"], "writable_binds" => [rw]})

    assert ["--ro-bind", ro, ro] in triples(args)
    assert ["--bind", rw, rw] in triples(args)
    refute Enum.member?(args, "/nonexistent-aiur-7783")
  end

  test "binds /etc/alternatives read-only when present", %{workspace: ws} do
    args = bwrap_args(ws, nil)
    expected = File.exists?("/etc/alternatives")
    assert ["--ro-bind", "/etc/alternatives", "/etc/alternatives"] in triples(args) == expected
  end

  test "configured path entry reaches PATH; unconfigured outside entry does not", %{root: root, workspace: ws} do
    tools = Path.join(root, "tools")
    elsewhere = Path.join(root, "elsewhere")
    previous = System.get_env("PATH")
    System.put_env("PATH", "#{tools}:#{elsewhere}:#{previous}")
    on_exit(fn -> System.put_env("PATH", previous) end)

    path = ws |> bwrap_args(%{"path" => [tools]}) |> sandbox_path() |> String.split(":")
    assert tools in path
    refute elsewhere in path

    refute tools in (ws |> bwrap_args(nil) |> sandbox_path() |> String.split(":"))
  end

  test "config validation refuses relative, root and ~/.aiur paths" do
    assert {:error, msg} = CommandSandbox.validate(%{"read_only_binds" => ["relative/dir"]})
    assert msg =~ "must be absolute"
    assert {:error, msg} = CommandSandbox.validate(%{"writable_binds" => ["/"]})
    assert msg =~ "must not be /"
    assert {:error, msg} = CommandSandbox.validate(%{"path" => [Path.join(System.user_home!(), ".aiur/instances")]})
    assert msg =~ "~/.aiur"
    assert {:error, msg} = CommandSandbox.validate(%{"read_only_binds" => ["/opt/../etc"]})
    assert msg =~ ".."
    assert :ok = CommandSandbox.validate(%{"read_only_binds" => ["/opt/node"], "path" => ["/opt/node/bin"]})
  end
end

defmodule Aiur.TestEnvironmentTest do
  use ExUnit.Case, async: false

  @sanitized_env_vars [
    "TMUX",
    "TMUX_PANE",
    "ERL_AFLAGS",
    "AIUR_DASHBOARD_USERNAME",
    "AIUR_DASHBOARD_PASSWORD",
    "AIUR_NODE",
    "AIUR_ERLANG_COOKIE",
    "AIUR_TMUX_CONF",
    "AIUR_TMUX_SESSION",
    "AIUR_TMUX_SOCKET",
    "XDG_RUNTIME_DIR"
  ]

  test "test setup removes env inherited from aiur shells" do
    assert Enum.all?(@sanitized_env_vars, &(System.get_env(&1) == nil))
  end

  test "test setup provides a writable HOME" do
    home = System.fetch_env!("HOME")
    probe = Path.join(home, "write-check")

    File.mkdir_p!(home)
    File.write!(probe, "ok")

    assert File.read!(probe) == "ok"
  end

  test "tests that change the global working directory are synchronous" do
    violations =
      Path.wildcard(Path.expand("../**/*_test.exs", __DIR__))
      |> Enum.filter(fn path ->
        ast = path |> File.read!() |> Code.string_to_quoted!()
        async_test?(ast) and changes_working_directory?(ast)
      end)

    assert violations == [], "File.cd/File.cd! cannot run in async tests: #{inspect(violations)}"
  end

  defp async_test?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}, options]} = node, found? ->
          {node, found? or Keyword.get(options, :async) == true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp changes_working_directory?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:File]}, function]}, _, _args} = node, _found?
        when function in [:cd, :cd!] ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end
end

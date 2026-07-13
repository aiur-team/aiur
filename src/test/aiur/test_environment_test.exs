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
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> cwd_violations()
        |> Enum.map(&"#{path}:#{&1}")
      end)

    assert violations == [], "cwd-changing calls cannot run in async tests: #{inspect(violations)}"
  end

  test "detects direct and indirect cwd mutations in async modules" do
    assert cwd_violations("""
           defmodule AsyncDirect do
             use ExUnit.Case, async: true
             File.cd("tmp")
           end

           defmodule AsyncDirectBang do
             use ExUnit.Case, async: true
             File.cd!("tmp")
           end

           defmodule AsyncAlias do
             use ExUnit.Case, async: true
             alias File, as: F
             F.cd("tmp")
           end

           defmodule AsyncImport do
             use ExUnit.Case, async: true
             import File
             cd!("tmp")
           end

           defmodule AsyncErlang do
             use ExUnit.Case, async: true
             :file.set_cwd(~c"tmp")
           end
           """) == ["AsyncDirect", "AsyncDirectBang", "AsyncAlias", "AsyncImport", "AsyncErlang"]
  end

  test "allows synchronous mutations and ignores non-code references" do
    assert cwd_violations(~S"""
           defmodule SyncMutation do
             use ExUnit.Case, async: false
             File.cd!("tmp")
           end

           defmodule AsyncReferences do
             use ExUnit.Case, async: true
             # File.cd!("tmp")
             @example "File.cd!(\"tmp\")"
           end
           """) == []
  end

  test "classifies cwd mutations per module" do
    assert cwd_violations("""
           defmodule AsyncClean do
             use ExUnit.Case, async: true
           end

           defmodule SyncMutation do
             use ExUnit.Case, async: false
             File.cd!("tmp")

             defmodule NestedAsyncClean do
               use ExUnit.Case, async: true
             end
           end
           """) == []
  end

  defp cwd_violations(source) do
    ast = Code.string_to_quoted!(source)

    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [name, [do: body]]} = node, modules ->
          {node, [{Macro.to_string(name), body} | modules]}

        node, modules ->
          {node, modules}
      end)

    modules
    |> Enum.reverse()
    |> Enum.filter(fn {_name, body} ->
      body = without_nested_modules(body)
      async_test?(body) and changes_working_directory?(body)
    end)
    |> Enum.map(&elem(&1, 0))
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
    file_aliases = file_aliases(ast)
    imports_file? = imports_file?(ast)

    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, alias_name}, function]}, _, _args} = node, found?
        when function in [:cd, :cd!] ->
          {node, found? or List.last(alias_name) in file_aliases}

        {{:., _, [:file, :set_cwd]}, _, _args} = node, _found? ->
          {node, true}

        {function, _, args} = node, _found? when imports_file? and function in [:cd, :cd!] and is_list(args) ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp without_nested_modules(ast) do
    Macro.prewalk(ast, fn
      {:defmodule, _, _} -> nil
      node -> node
    end)
  end

  defp file_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, MapSet.new([:File]), fn
        {:alias, _, [{:__aliases__, _, [:File]}, options]} = node, aliases ->
          alias_name = options |> Keyword.get(:as, {:__aliases__, [], [:File]}) |> elem(2) |> List.last()
          {node, MapSet.put(aliases, alias_name)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp imports_file?(ast) do
    {_ast, imported?} =
      Macro.prewalk(ast, false, fn
        {:import, _, [{:__aliases__, _, [:File]} | _]} = node, _imported? -> {node, true}
        node, imported? -> {node, imported?}
      end)

    imported?
  end
end

defmodule Aiur.TestCwdGuard do
  @file_cwd_functions MapSet.new(cd: 1, cd: 2, cd!: 1, cd!: 2)

  def violations(source) do
    source
    |> Code.string_to_quoted!()
    |> scan_scope(new_env(), MapSet.new())
    |> elem(2)
  end

  defp scan_scope({:__block__, _, expressions}, env, locals) do
    Enum.reduce(expressions, {env, false, []}, fn expression, {env, mutation?, modules} ->
      {env, expression_mutation?, expression_modules} = scan_expression(expression, env, locals)
      {env, mutation? or expression_mutation?, modules ++ expression_modules}
    end)
  end

  defp scan_scope(expression, env, locals), do: scan_expression(expression, env, locals)

  defp scan_expression({:quote, _, _}, env, _locals), do: {env, false, []}

  defp scan_expression({:alias, _, [{:__aliases__, _, target} | options]}, env, _locals) do
    target = resolve_alias(target, env.aliases)
    options = directive_options(options)
    alias_name = options |> Keyword.get(:as) |> alias_name(target)
    {%{env | aliases: Map.put(env.aliases, alias_name, target)}, false, []}
  end

  defp scan_expression({:import, _, [{:__aliases__, _, target} | options]}, env, _locals) do
    target = resolve_alias(target, env.aliases)
    options = directive_options(options)
    imports = if target == [:File], do: imported_file_functions(options), else: env.imports
    {%{env | imports: imports}, false, []}
  end

  defp scan_expression({:defmodule, _, [name, [do: body]]}, env, _locals) do
    locals = local_definitions(body)
    {_module_env, mutation?, nested_modules, async?} = scan_module_body(body, env, locals)
    module_name = Macro.to_string(name)
    modules = if async? and mutation?, do: [module_name | nested_modules], else: nested_modules
    {register_module_alias(env, name), false, modules}
  end

  defp scan_expression({kind, _, [_head, body_options]}, env, locals)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(body_options) do
    {_function_env, mutation?, modules} = scan_scope(Keyword.get(body_options, :do), env, locals)
    {env, mutation?, modules}
  end

  defp scan_expression(expression, env, locals) do
    mutation? = cwd_mutation?(expression, env, locals)
    {_child_env, child_mutation?, modules} = scan_children(expression, env, locals)
    {env, mutation? or child_mutation?, modules}
  end

  defp scan_module_body(body, inherited_env, locals) do
    expressions = if match?({:__block__, _, _}, body), do: elem(body, 2), else: [body]

    Enum.reduce(expressions, {inherited_env, false, [], false}, fn expression, {env, mutation?, modules, async?} ->
      expression_async? = async_exunit_use?(expression, env)
      {env, expression_mutation?, expression_modules} = scan_expression(expression, env, locals)

      {
        env,
        mutation? or expression_mutation?,
        modules ++ expression_modules,
        async? or expression_async?
      }
    end)
  end

  defp scan_children(expression, env, locals) when is_list(expression) do
    Enum.reduce(expression, {env, false, []}, fn child, {_env, mutation?, modules} ->
      {_child_env, child_mutation?, child_modules} = scan_scope(child, env, locals)
      {env, mutation? or child_mutation?, modules ++ child_modules}
    end)
  end

  defp scan_children(expression, env, locals) when is_tuple(expression) do
    expression
    |> Tuple.to_list()
    |> scan_children(env, locals)
  end

  defp scan_children(_expression, env, _locals), do: {env, false, []}

  defp cwd_mutation?({{:., _, [{:__aliases__, _, target}, function]}, _, args}, env, _locals)
       when function in [:cd, :cd!] and is_list(args) do
    resolve_alias(target, env.aliases) == [:File] and {function, length(args)} in @file_cwd_functions
  end

  defp cwd_mutation?({{:., _, [:file, :set_cwd]}, _, [_path]}, _env, _locals), do: true

  defp cwd_mutation?({function, _, args}, env, locals)
       when function in [:cd, :cd!] and is_list(args) do
    signature = {function, length(args)}
    signature in env.imports and signature not in locals
  end

  defp cwd_mutation?(_expression, _env, _locals), do: false

  defp async_exunit_use?({:use, _, [{:__aliases__, _, target}, options]}, env) do
    resolve_alias(target, env.aliases) == [:ExUnit, :Case] and Keyword.get(options, :async) == true
  end

  defp async_exunit_use?(_expression, _env), do: false

  defp local_definitions(body) do
    body
    |> direct_expressions()
    |> Enum.reduce(MapSet.new(), fn
      {kind, _, [head | _]}, definitions when kind in [:def, :defp, :defmacro, :defmacrop] ->
        add_definition(definitions, head)

      _expression, definitions ->
        definitions
    end)
  end

  defp add_definition(definitions, {:when, _, [head | _guards]}), do: add_definition(definitions, head)

  defp add_definition(definitions, {name, _, args}) when is_atom(name) and is_list(args) do
    maximum_arity = length(args)
    default_count = Enum.count(args, &match?({:\\, _, _}, &1))

    Enum.reduce((maximum_arity - default_count)..maximum_arity, definitions, fn arity, definitions ->
      MapSet.put(definitions, {name, arity})
    end)
  end

  defp add_definition(definitions, _head), do: definitions

  defp direct_expressions({:__block__, _, expressions}), do: expressions
  defp direct_expressions(expression), do: [expression]

  defp imported_file_functions(options) do
    imports =
      case Keyword.get(options, :only) do
        nil -> @file_cwd_functions
        functions -> MapSet.intersection(@file_cwd_functions, MapSet.new(functions))
      end

    case Keyword.get(options, :except) do
      nil -> imports
      functions -> MapSet.difference(imports, MapSet.new(functions))
    end
  end

  defp resolve_alias([:"Elixir" | target], _aliases), do: target

  defp resolve_alias([first | rest] = target, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, resolved} -> resolved ++ rest
      :error -> target
    end
  end

  defp alias_name(nil, target), do: List.last(target)
  defp alias_name({:__aliases__, _, target}, _resolved_target), do: List.last(target)

  defp register_module_alias(env, {:__aliases__, _, target}) do
    target = resolve_alias(target, env.aliases)
    alias_name = List.last(target)
    %{env | aliases: Map.put(env.aliases, alias_name, [:nested_module | target])}
  end

  defp register_module_alias(env, _dynamic_name), do: env

  defp directive_options([options]) when is_list(options), do: options
  defp directive_options(_options), do: []

  defp new_env, do: %{aliases: %{}, imports: MapSet.new()}
end

defmodule Aiur.TestEnvironmentTest do
  use ExUnit.Case, async: false

  alias Aiur.TestCwdGuard, as: CwdGuard

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
        |> CwdGuard.violations()
        |> Enum.map(&"#{path}:#{&1}")
      end)

    assert violations == [], "cwd-changing calls cannot run in async tests: #{inspect(violations)}"
  end

  test "detects qualified aliases and imports" do
    assert CwdGuard.violations("""
           defmodule Qualified do
             use Elixir.ExUnit.Case, async: true
             alias Elixir.File, as: F
             F.cd!("tmp")
           end

           defmodule Imported do
             use Elixir.ExUnit.Case, async: true
             import Elixir.File, only: [cd!: 1]
             cd!("tmp")
           end
           """) == ["Qualified", "Imported"]
  end

  test "honors import filters and local definitions" do
    assert CwdGuard.violations("""
           defmodule OnlyRead do
             use ExUnit.Case, async: true
             import File, only: [read!: 1]
             cd!("local")
           end

           defmodule ExceptCwd do
             use ExUnit.Case, async: true
             import File, except: [cd: 1, cd!: 1]
             cd("local")
             cd!("local")
           end

           defmodule LocalDefinition do
             use ExUnit.Case, async: true
             import File
             defp cd!(path), do: path
             cd!("local")
           end
           """) == []
  end

  test "resolves aliases in lexical order and inherits them in nested modules" do
    assert CwdGuard.violations("""
           defmodule Shadowed do
             use ExUnit.Case, async: true
             alias Other, as: File
             File.cd!("not-file")
           end

           defmodule Outer do
             alias Elixir.File, as: F

             defmodule Nested do
               use ExUnit.Case, async: true
               F.cd!("tmp")
             end
           end
           """) == ["Nested"]
  end

  test "absolute roots bypass shadows and nested modules introduce aliases" do
    assert CwdGuard.violations("""
           defmodule AbsoluteRoots do
             alias Other, as: File
             alias Other, as: ExUnit
             use Elixir.ExUnit.Case, async: true
             Elixir.File.cd!("tmp")
           end

           defmodule Outer do
             use ExUnit.Case, async: true

             defmodule File do
             end

             File.cd!("nested-module-call")
           end
           """) == ["AbsoluteRoots"]
  end

  test "skips quoted modules and mutations" do
    assert CwdGuard.violations("""
           quote do
             defmodule Generated do
               use ExUnit.Case, async: true
               File.cd!("tmp")
             end
           end

           defmodule Live do
             use ExUnit.Case, async: true
             quote do: File.cd!("tmp")
           end
           """) == []
  end

  test "detects direct calls and Erlang cwd mutations" do
    assert CwdGuard.violations("""
           defmodule Direct do
             use ExUnit.Case, async: true
             File.cd("tmp")
             File.cd!("tmp")
           end

           defmodule Erlang do
             use ExUnit.Case, async: true
             :file.set_cwd(~c"tmp")
           end
           """) == ["Direct", "Erlang"]
  end

  test "allows synchronous calls and ignores comments and strings" do
    assert CwdGuard.violations(~S"""
           defmodule Synchronous do
             use ExUnit.Case, async: false
             File.cd!("tmp")
           end

           defmodule References do
             use ExUnit.Case, async: true
             # File.cd!("tmp")
             @example "File.cd!(\"tmp\")"
           end
           """) == []
  end
end

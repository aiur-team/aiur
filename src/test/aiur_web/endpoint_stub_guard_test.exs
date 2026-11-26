defmodule AiurWeb.EndpointStubGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.EndpointConfig

  # A function or process in the global `AiurWeb.Endpoint` config is called by
  # every other test that renders a dashboard (#4838, #4862, #4892). Scope it to
  # the test with `Aiur.TestSupport.EndpointStubs.put/1` or `scope/1` (#4908).
  @test_root Path.expand("..", __DIR__)
  # Standalone fixture servers: their HTTP requests have no test caller to scope to.
  @exempt ~w(browser manual)
  # The guard's own tests write stubs on purpose.
  @guard_tests ~w(aiur_web/endpoint_stub_guard_test.exs aiur_web/endpoint_stub_refusal_test.exs)
  @endpoint_aliases [[:Endpoint], [:AiurWeb, :Endpoint]]

  test "no test writes a function or self() into the global endpoint config" do
    offenders =
      for path <- Path.wildcard(Path.join(@test_root, "**/*.{ex,exs}")),
          relative = Path.relative_to(path, @test_root),
          hd(Path.split(relative)) not in @exempt,
          relative not in @guard_tests,
          line <- global_stub_writes(path),
          do: "#{relative}:#{line}"

    assert offenders == []
  end

  test "the scan sees literal stubs that skip EndpointStubs.scope/1" do
    source = ~S"""
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.merge(config, open_tickets_fun: fn -> [] end))
    Endpoint.config_change([{Endpoint, [units_fleet_fun: &fleet/0]}], [])
    Phoenix.Config.put(Endpoint, :decision_store, self())
    Application.put_env(:aiur, AiurWeb.Endpoint, server: false)
    Application.put_env(:aiur, Endpoint, EndpointStubs.scope(open_tickets_fun: fn -> [] end))
    """

    assert source |> Code.string_to_quoted!() |> stub_lines() == [1, 2, 3]
  end

  test "a scoped stub is visible to the test and its callers only" do
    Aiur.TestSupport.start_owned_endpoint!()
    stub = fn -> :stubbed end
    assert EndpointStubs.scope(open_tickets_fun: stub, snapshot_timeout_ms: 5) == [snapshot_timeout_ms: 5]

    assert EndpointConfig.get(:open_tickets_fun) == stub
    assert Task.await(Task.async(fn -> EndpointConfig.get(:open_tickets_fun) end)) == stub

    foreign = spawn_link_and_get(:open_tickets_fun)
    refute foreign == stub
  end

  defp spawn_link_and_get(key) do
    parent = self()
    ref = make_ref()
    spawn_link(fn -> send(parent, {ref, EndpointConfig.get(key)}) end)

    receive do
      {^ref, value} -> value
    after
      5_000 -> flunk("foreign process did not answer")
    end
  end

  defp global_stub_writes(path) do
    path |> File.read!() |> Code.string_to_quoted!() |> stub_lines()
  end

  defp stub_lines(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        case global_write_value(node) do
          {:ok, line, value} -> {node, if(stub?(value), do: [line | acc], else: acc)}
          :error -> {node, acc}
        end
      end)

    Enum.sort(lines)
  end

  defp global_write_value({{:., meta, [{:__aliases__, _, [:Application]}, :put_env]}, _, [:aiur, {:__aliases__, _, name}, value | _]})
       when name in @endpoint_aliases,
       do: {:ok, meta[:line], value}

  defp global_write_value({{:., meta, [{:__aliases__, _, name}, :config_change]}, _, [value | _]}) when name in @endpoint_aliases,
    do: {:ok, meta[:line], value}

  defp global_write_value({{:., meta, [{:__aliases__, _, [:Phoenix, :Config]}, :put]}, _, [{:__aliases__, _, name}, _key, value]})
       when name in @endpoint_aliases,
       do: {:ok, meta[:line], value}

  defp global_write_value(_node), do: :error

  # A value passed through `EndpointStubs.scope/1` keeps only plain values.
  defp stub?(value), do: contains?(value, &stub_node?/1) and not contains?(value, &scope_call?/1)

  defp stub_node?({:fn, _, _}), do: true
  defp stub_node?({:&, _, _}), do: true
  defp stub_node?({:self, _, []}), do: true
  defp stub_node?(_node), do: false

  defp scope_call?({{:., _, [{:__aliases__, _, aliases}, :scope]}, _, _}), do: List.last(aliases) == :EndpointStubs
  defp scope_call?(_node), do: false

  defp contains?(ast, match?) do
    {_ast, found?} = Macro.prewalk(ast, false, fn node, found? -> {node, found? or match?.(node)} end)
    found?
  end
end

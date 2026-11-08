defmodule Aiur.ControlCall.AllowlistCategoryTest do
  use ExUnit.Case, async: true

  alias Aiur.ControlCall.Allowlist

  @agent "Aiur.AgentControlCLI"
  @legal Allowlist.categories() ++ [:deny]

  test "no entry can resolve to trust or a bare write class" do
    refute :trust in Allowlist.categories()
    assert_raise FunctionClauseError, fn -> Allowlist.scope_of(:trust) end
    assert_raise FunctionClauseError, fn -> Allowlist.scope_of(:write) end

    for {key, %{class: class}} <- Allowlist.entries(), not is_function(class) do
      assert class in @legal, "#{inspect(key)} has class #{inspect(class)}"
    end
  end

  test "category functions only return legal categories" do
    probes = [
      [],
      [[mode: :full]],
      [[mode: :changes]],
      [[op: :show]],
      [[op: :edit]],
      [[action: :list]],
      [[action: :set]],
      [[verb: :show]],
      [[verb: :create]],
      [[verb: :order, to: 1]],
      [[apply: true]],
      [[hours: 2.0]],
      [[action: :pause]],
      [[argv: ["ack"]]],
      [1, ["x"]],
      [1, []]
    ]

    for {key, %{class: class}} <- Allowlist.entries(), is_function(class, 1), args <- probes do
      result = try_class(class, args)
      assert result in [:error | @legal], "#{inspect(key)} #{inspect(args)} -> #{inspect(result)}"
    end
  end

  test "scope follows from the category" do
    assert Allowlist.scope_of(:read) == :read
    assert Allowlist.scope_of(:deny) == :deny
    for c <- Allowlist.categories() -- [:read], do: assert(Allowlist.scope_of(c) == :write)
  end

  test "parse assigns the ticket's categories" do
    cases = [
      {"#{@agent}.pause([\"1\"])", :agents},
      {"#{@agent}.resume([\"1\"])", :agents},
      {"#{@agent}.park([\"1\"])", :agents},
      {"#{@agent}.redispatch([\"1\"], nil)", :agents},
      {"#{@agent}.todo([\"1\"])", :tickets},
      {"#{@agent}.take([\"1\"], \"me\")", :tickets},
      {"#{@agent}.release([\"1\"], \"me\")", :tickets},
      {"#{@agent}.set_max_agents(2)", :config},
      {"#{@agent}.message(\"1\", \"hi\")", :message},
      {"#{@agent}.executor_claim()", :executor},
      {"#{@agent}.status()", :read}
    ]

    for {expression, category} <- cases do
      assert {:ok, %{category: ^category}} = Aiur.ControlCall.parse(expression, remote: true), expression
    end

    assert {:ok, %{category: :agents, scope: :write}} = Aiur.ControlCall.parse("#{@agent}.pause([\"123\"])", remote: true)
  end

  defp try_class(class, args) do
    class.(args)
  rescue
    _ -> :error
  end
end

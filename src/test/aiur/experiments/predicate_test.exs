defmodule Aiur.Experiments.PredicateTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Predicate

  test "nested all/not predicates assign by cohort attributes" do
    predicate = %{"all" => [%{"attr" => "backend", "op" => "eq", "value" => "claude"}, %{"not" => %{"attr" => "model", "op" => "prefix", "value" => "gpt-"}}]}
    assert Predicate.validate(predicate) == []
    assert Predicate.matches?(predicate, %{"backend" => "claude", "model" => "sonnet"})
    refute Predicate.matches?(predicate, %{"backend" => "claude", "model" => "gpt-5"})
    refute Predicate.matches?(predicate, %{"backend" => "codex", "model" => "sonnet"})
  end

  test "in requires a list, operators and attributes are closed" do
    assert [%{path: "predicate.value", message: "in requires a list"}] = Predicate.validate(%{"attr" => "backend", "op" => "in", "value" => "claude"})
    assert [%{path: "predicate.attr", message: "unknown cohort attribute"}] = Predicate.validate(%{"attr" => "colour", "op" => "eq", "value" => "red"})
    assert [%{path: "predicate.op", message: "unknown predicate operator"}] = Predicate.validate(%{"attr" => "backend", "op" => "execute", "value" => "command"})
  end

  test "exists distinguishes absent keys and supports tags" do
    predicate = %{"attr" => "tags.team", "op" => "exists"}
    assert Predicate.validate(predicate) == []
    assert Predicate.matches?(predicate, %{"tags" => %{"team" => "platform"}})
    refute Predicate.matches?(predicate, %{"tags" => %{}})
    refute Predicate.matches?(predicate, %{})
    assert Predicate.matches?(Map.put(predicate, "value", false), %{})
  end

  test "any, neq and in evaluate values without executing code" do
    predicate = %{"any" => [%{"attr" => "backend", "op" => "in", "value" => ["claude", "codex"]}, %{"attr" => "complexity", "op" => "neq", "value" => 1}]}
    assert Predicate.matches?(predicate, %{"backend" => "codex", "complexity" => 1})
    assert Predicate.matches?(predicate, %{"backend" => "other", "complexity" => 3})
    refute Predicate.matches?(predicate, %{"backend" => "other", "complexity" => 1})
    refute Predicate.matches?(%{"attr" => "model", "op" => "prefix", "value" => 3}, %{"model" => "anything"})
  end
end

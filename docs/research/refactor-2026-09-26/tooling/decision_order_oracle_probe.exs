# Usage: elixir tooling/decision_order_oracle_probe.exs SNAPSHOT
# Executes extracted assertions against supplied messages/audits; no application boot.
[root] = System.argv()
:ok = Application.load(:ex_unit)
attention = File.read!(Path.join(root, "src/test/aiur/decision_attention_test.exs"))
lines = String.split(attention, "\n")
receives = Enum.filter(lines, &(&1 in [
  "    assert_receive {:step, :projected, payload, opts}",
  "    assert_receive {:step, :alerted, %{slug: \"scope-question\"}}"
]))
unless length(receives) == 2, do: raise("expected two exact attention receives")

defmodule OracleProbe do
  def outcome(code, bindings) do
    try do
      Code.eval_string("import ExUnit.Assertions\n" <> code, bindings)
      :passes
    rescue
      ExUnit.AssertionError -> :fails
    end
  end

  def drain do
    receive do
      {:step, _, _} -> drain()
      {:step, _, _, _} -> drain()
    after
      0 -> :ok
    end
  end
end

for {name, code, reverse?, expected} <- [
  {:attention_original_reversed, Enum.join(receives, "\n"), true, :passes},
  {:attention_control_reversed, """
  assert_receive actual
  assert elem(actual, 1) == :projected
  """, true, :fails},
  {:attention_control_valid, """
  assert_receive actual
  assert elem(actual, 1) == :projected
  """, false, :passes}
] do
  messages = [{:step, :projected, %{}, []}, {:step, :alerted, %{slug: "scope-question"}}]
  for message <- (if reverse?, do: Enum.reverse(messages), else: messages), do: send(self(), message)
  result = OracleProbe.outcome(code, [])
  IO.inspect({name, result})
  unless result == expected, do: raise("unexpected attention result")
  OracleProbe.drain()
end

defmodule DecisionEvent do
  defstruct [:type, :data]
end

revision = File.read!(Path.join(root, "src/test/aiur/decision_revision_store_test.exs"))
audit_lines = revision |> String.split("\n") |> Enum.filter(fn line ->
  String.starts_with?(line, "    second_index = Enum.find_index(audit,") or
    String.starts_with?(line, "    handled_index = Enum.find_index(audit,") or
    line == "    assert second_index < handled_index"
end)
unless length(audit_lines) == 3, do: raise("expected three exact audit assertions")
original = Enum.join(audit_lines, "\n")
control = String.replace(original, "assert second_index < handled_index",
  "assert is_integer(second_index) and is_integer(handled_index)\nassert second_index < handled_index")
second = %{action_id: "second"}
revision_event = struct(DecisionEvent, type: :revision_recorded, data: second)
handled_event = struct(DecisionEvent, type: :follow_up_handled, data: %{})
for {name, audit, code, expected} <- [
  {:audit_original_valid, [revision_event, handled_event], original, :passes},
  {:audit_original_missing_handled, [revision_event], original, :passes},
  {:audit_control_valid, [revision_event, handled_event], control, :passes},
  {:audit_control_missing_handled, [revision_event], control, :fails}
] do
  result = OracleProbe.outcome(code, audit: audit, second: second)
  IO.inspect({name, result})
  unless result == expected, do: raise("unexpected audit result")
end

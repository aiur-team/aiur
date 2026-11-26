defmodule Aiur.Ownership.RecordTest do
  use ExUnit.Case, async: true

  alias Aiur.Ownership.Record

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        repo: "o/r",
        ticket: "123",
        state: "owned",
        gateway_id: String.duplicate("a", 26),
        gateway_label: "pc",
        daemon_key: "pc",
        epoch: 1,
        previous_epoch: 0,
        actor: %{kind: "daemon", id: "pc"},
        reason: "dispatch",
        at: "2026-11-07T00:00:00Z"
      },
      overrides
    )
  end

  test "round trips through encode and decode with stable bytes" do
    {:ok, record} = Record.new(attrs())
    bytes = Record.encode(record)

    assert bytes == Record.encode(record)
    assert String.starts_with?(bytes, ~s({"schema":"aiur.ownership/v1","repo":"o/r","ticket":"123"))
    assert {:ok, ^record} = Record.decode(bytes)
  end

  test "keys are written in S1 order and daemon_key sits beside gateway_id" do
    {:ok, record} = Record.new(attrs())
    keys = record |> Record.encode() |> Jason.decode!(objects: :ordered_objects) |> Map.fetch!(:values) |> Enum.map(&elem(&1, 0))

    assert keys == ~w(schema repo ticket state gateway_id gateway_label daemon_key epoch previous_epoch actor reason at)
  end

  test "rejects each invalid field" do
    for {override, field} <- [
          {%{daemon_key: nil}, :daemon_key},
          {%{previous_epoch: 1}, :previous_epoch},
          {%{state: "held"}, :state},
          {%{actor: %{kind: "bot", id: "x"}}, :actor},
          {%{reason: "x"}, :reason},
          {%{gateway_id: String.duplicate("a", 25)}, :gateway_id},
          {%{at: "2026-11-07T00:00:00+02:00"}, :at}
        ] do
      assert Record.new(attrs(override)) == {:error, {:invalid, field}}
    end
  end

  test "decode refuses an unknown schema, ignores extra keys, and does not raise on junk" do
    {:ok, record} = Record.new(attrs())
    json = Record.encode(record)

    assert {:error, {:unsupported_schema, "aiur.ownership/v2"}} =
             json |> String.replace("v1", "v2") |> Record.decode()

    assert {:ok, ^record} = json |> String.replace_suffix("}", ~s(,"future":1})) |> Record.decode()
    assert {:error, _} = Record.decode("nope")
  end
end

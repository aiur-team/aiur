defmodule Aiur.InstanceSummary.RedactionTest do
  use ExUnit.Case, async: true

  alias Aiur.InstanceSummary
  alias Aiur.InstanceSummary.Fact

  defp summary(fact), do: InstanceSummary.v1(instance_id: fn -> nil end, providers: %{executor: fn -> fact end})
  defp available(value), do: Fact.available(value, DateTime.to_iso8601(DateTime.utc_now()))

  defp reject_values(values) do
    for value <- values, payload <- [value, %{consumers: [%{identity: value}]}] do
      error = assert_raise ArgumentError, fn -> summary(available(payload)) end
      assert Exception.message(error) == "instance summary contains a forbidden value"
      refute String.contains?(Exception.message(error), value)
    end
  end

  test "credential strings are rejected in scalar and nested values" do
    reject_values([
      "ghp_" <> String.duplicate("a", 36),
      "github_pat_" <> String.duplicate("b", 40),
      "gho_" <> String.duplicate("c", 36),
      "ghs_" <> String.duplicate("d", 36),
      "sk-" <> String.duplicate("e", 24),
      "Bearer private_credential"
    ])
  end

  test "sensitive atoms are rejected before JSON encodes them as strings" do
    for value <- [:ghp_sensitive, :"/home/operator/private", :"host.internal"] do
      assert_raise ArgumentError, "instance summary contains a forbidden value", fn -> summary(available(value)) end
    end
  end

  test "opaque hex and base64 values are rejected" do
    reject_values([String.duplicate("abc123", 8), Base.encode64(String.duplicate("private", 12))])
  end

  test "home and absolute paths are rejected in scalar and nested values" do
    reject_values(["/home/operator/private", "~/private", "/var/run/private", "C:\\Users\\operator\\private", "failed at /home/operator/private", "file=/home/operator/private"])
  end

  test "hostnames and URLs are rejected in scalar and nested values" do
    reject_values(["private-host.example.com", "https://private-host.example.com/path", "host.internal", "127.0.0.1", "localhost", "worker:4000", "\"worker:4000\"", "custom://host"])
  end

  test "reason paths and other non-code reasons are rejected" do
    for reason <- ["/home/operator/private", "offline/path", "Offline", "offline host", "", String.duplicate("a", 65)] do
      error = assert_raise ArgumentError, fn -> summary(Fact.unknown(reason)) end
      assert Exception.message(error) == "instance summary contains a forbidden value"
    end
  end

  test "contract timestamps UUID identity and reason codes remain valid" do
    instance_id = "550e8400-e29b-41d4-a716-446655440000/run"
    result = InstanceSummary.v1(instance_id: fn -> instance_id end, providers: %{executor: fn -> Fact.unknown("not_running") end})
    assert result.instance_id == instance_id
    assert result.contract == "aiur.instance_summary"
    assert result.executor.reason == "not_running"
    assert summary(Fact.unknown(String.duplicate("a", 64))).executor.reason == String.duplicate("a", 64)
    assert {:ok, _, _} = DateTime.from_iso8601(result.observed_at)
  end
end

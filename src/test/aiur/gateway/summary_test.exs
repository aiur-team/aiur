defmodule Aiur.Gateway.SummaryTest do
  use ExUnit.Case, async: true

  alias Aiur.Gateway.Summary

  defp build(data, now \\ ~U[2026-11-06 12:00:05Z]), do: Summary.build(now_fun: fn -> now end, metadata_fun: fn -> data end)

  test "every project carries observed_at and age_ms" do
    data = %{"data" => %{"agent_count" => 3, "agent_capacity" => 8, "projects" => [%{"repo" => "acme/widgets", "running" => 2, "owned_tickets" => 2}, %{"repo" => "acme/api", "running" => 1}]}}
    summary = build(data)

    assert [%{repo: "acme/widgets", observed_at: "2026-11-06T12:00:05Z", age_ms: 0, running: 2}, %{repo: "acme/api", observed_at: "2026-11-06T12:00:05Z", age_ms: 0}] = summary.projects
    assert summary.workload == "active"
  end

  test "unreadable values are nil, never zero" do
    summary = build(%{})

    assert summary.capacity == %{max: nil, running: nil}
    assert summary.workload == nil
    assert summary.projects == []
    assert summary.executor_present == nil
    summary = build(%{"data" => %{"projects" => [%{"repo" => "a/b"}]}})
    assert [%{owned_tickets: nil, running: nil, ready: nil, paused: nil, pending_decisions: nil, focus_features: nil}] = summary.projects
  end

  test "a failing reader degrades to nulls" do
    assert Summary.build(metadata_fun: fn -> raise "boom" end).capacity == %{max: nil, running: nil}
  end

  test "workload rules" do
    for {running, max, expected} <- [{0, 8, "idle"}, {3, 8, "active"}, {8, 8, "saturated"}] do
      assert build(%{"data" => %{"agent_count" => running, "agent_capacity" => max}}).workload == expected
    end
  end
end

defmodule Aiur.Gateway.SummaryMetadataSourceTest do
  use ExUnit.Case, async: false

  test "default metadata comes from the :gateway_summary_metadata hook set at boot" do
    previous = Application.get_env(:aiur, :gateway_summary_metadata)
    Application.put_env(:aiur, :gateway_summary_metadata, fn -> %{"data" => %{"agent_count" => 2, "agent_capacity" => 5}} end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :gateway_summary_metadata, previous),
        else: Application.delete_env(:aiur, :gateway_summary_metadata)
    end)

    assert Aiur.Gateway.Summary.build().capacity == %{max: 5, running: 2}
  end
end

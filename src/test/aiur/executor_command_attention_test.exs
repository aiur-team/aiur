defmodule Aiur.ExecutorCommandAttentionTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorCommandAttention

  @decision %{decision_id: "decision:42", version: 3, ticket: %{identifier: "42"}}

  test "derives a stable ticket-scoped escalation topic" do
    topic = ExecutorCommandAttention.topic("decision:42", "42")
    assert topic =~ ~r/^ticket\.42\.agent\.attention\.executor-command-[0-9a-f]{16}$/
    assert ExecutorCommandAttention.topic("decision:42", "42") == topic
  end

  test "opens once per version and resolves only a durable active escalation" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "executor-command-attention-#{System.pid()}-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, :opened} =
             ExecutorCommandAttention.open(@decision, "executor-1", "Scope change",
               marker_path: path,
               alert_fun: fn topic, message, opts ->
                 send(parent, {:opened, topic, message, opts})
                 :ok
               end
             )

    assert_received {:opened, topic, message, open_opts}
    assert topic == ExecutorCommandAttention.topic("decision:42", "42")
    assert message =~ "Executor executor-1 escalated"
    assert open_opts[:needs_attention] == true

    assert {:ok, :already_open} =
             ExecutorCommandAttention.open(@decision, "executor-1", "Scope change",
               marker_path: path,
               alert_fun: fn _, _, _ -> flunk("same-version replay must not emit") end
             )

    assert :ok =
             ExecutorCommandAttention.resolve(@decision,
               marker_path: path,
               alert_fun: fn topic, opts ->
                 send(parent, {:resolved, topic, opts})
                 :ok
               end
             )

    assert_received {:resolved, topic, opts}
    assert String.ends_with?(topic, ".resolved")
    assert opts[:needs_attention] == false
    assert opts[:issue] == "42"
    refute File.exists?(path)

    assert :ok =
             ExecutorCommandAttention.resolve(@decision,
               marker_path: path,
               alert_fun: fn _, _ -> flunk("inactive escalation must not emit") end
             )
  end

  test "retains pending state when alert delivery fails and completes on retry" do
    path = Path.join(System.tmp_dir!(), "executor-command-attention-retry-#{System.pid()}-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :alert_unavailable} =
             ExecutorCommandAttention.open(@decision, "executor-1", "Scope change",
               marker_path: path,
               alert_fun: fn _, _, _ -> {:error, :alert_unavailable} end
             )

    assert {:ok, %{"state" => "pending", "executor_id" => "executor-1"}} = Aiur.JsonStore.read(path)

    assert {:ok, :opened} =
             ExecutorCommandAttention.open(@decision, "executor-1", "Scope change",
               marker_path: path,
               alert_fun: fn _, _, _ -> :ok end
             )

    assert {:ok, %{"state" => "open"}} = Aiur.JsonStore.read(path)
  end
end

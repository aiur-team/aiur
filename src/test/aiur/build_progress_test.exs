defmodule Aiur.BuildProgressTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildProgress, JsonStore}
  alias Aiur.Events.Exchange

  setup do
    dir = Aiur.TestSupport.tmp_root!("build-progress")
    File.mkdir_p!(dir)
    path = Path.join(dir, "build-progress.json")
    scope = {:queue, "progress-#{System.unique_integer([:positive])}"}
    :ok = Exchange.subscribe(topic(scope))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: path, scope: scope}
  end

  test "20% to 80% emits only the highest milestone and stores its latch", context do
    server = start_store(context.path)
    put(server, context.scope, 20)
    refute_received {:event, %{topic: _}}
    put(server, context.scope, 80)
    assert_received {:event, event}
    assert event.topic == topic(context.scope)
    assert event.milestone == 75
    assert event.percent == 80
    assert event.generation == 1
    assert event["severity"] == "info"
    assert event["needs_attention"] == false
    assert {:ok, latches} = JsonStore.read(context.path)
    {kind, id} = context.scope
    assert latches[Jason.encode!([kind, id, 1])] == 75
    refute_received {:event, %{topic: _}}
  end

  test "restart at 80% emits nothing and decreases never reset the latch", context do
    server = start_store(context.path)
    put(server, context.scope, 80)
    assert_received {:event, %{milestone: 75}}
    GenServer.stop(server)
    restarted = start_store(context.path)
    put(restarted, context.scope, 80)
    put(restarted, context.scope, 25)
    put(restarted, context.scope, 80)
    refute_received {:event, %{topic: _}}
    put(restarted, context.scope, 100)
    assert_received {:event, %{milestone: 100}}
  end

  test "partial resolution emits; unresolved and unknown do not", context do
    server = start_store(context.path)
    put(server, context.scope, 25, resolution: :unresolved)
    put(server, context.scope, 25, resolution: :unknown)
    refute_received {:event, %{topic: _}}
    put(server, context.scope, 25, resolution: :partial)
    assert_received {:event, %{milestone: 25}}
  end

  test "stale and unknown freshness suppress milestones until current", context do
    server = start_store(context.path)
    put(server, context.scope, 50, freshness: :stale)
    put(server, context.scope, 50, freshness: :unknown)
    refute_received {:event, %{topic: _}}
    put(server, context.scope, 50)
    assert_received {:event, %{milestone: 50}}
  end

  test "unknown percent never latches milestones with resolved or partial resolution", context do
    server = start_store(context.path)

    for {resolution, generation} <- [resolved: 1, partial: 2] do
      unknown = put(server, context.scope, nil, resolution: resolution, generation: generation)
      assert unknown.freshness == :current
      assert BuildProgress.facts(context.scope, server) == [unknown]
      refute_received {:event, %{topic: _}}
      put(server, context.scope, 25, resolution: resolution, generation: generation)
      assert_received {:event, %{milestone: 25, generation: ^generation}}
    end
  end

  test "new generation after 100 starts at 25 without resetting an older generation", context do
    server = start_store(context.path)
    put(server, context.scope, 100)
    assert_received {:event, %{milestone: 100, generation: 1}}
    put(server, context.scope, 25, generation: 2)
    assert_received {:event, %{milestone: 25, generation: 2}}
    put(server, context.scope, 100)
    refute_received {:event, %{topic: _}}
  end

  test "signals changes including decreases and generations, but not identical or timestamp-only updates", context do
    server = start_store(context.path)
    :ok = BuildProgress.subscribe()
    initial = put(server, context.scope, 20)
    assert_received {:build_progress_changed, ^initial}
    assert :ok = BuildProgress.put_fact(initial, server)
    later = %{initial | observed_at: DateTime.add(initial.observed_at, 1)}
    assert :ok = BuildProgress.put_fact(later, server)
    refute_received {:build_progress_changed, _}
    assert BuildProgress.facts(context.scope, server) == [later]

    Enum.reduce([[percent: 10], [resolution: :partial], [freshness: :stale], [generation: 2]], later, fn attrs, previous ->
      changed = Map.merge(previous, Map.new(attrs))
      assert :ok = BuildProgress.put_fact(changed, server)
      assert_received {:build_progress_changed, ^changed}
      changed
    end)
  end

  test "facts read all scopes or one, with independent queue and build-order milestones", context do
    server = start_store(context.path)
    root = {:build_order, System.unique_integer([:positive])}
    :ok = Exchange.subscribe(topic(root))
    first = put(server, context.scope, 25)
    second = put(server, root, 25)
    assert_received {:event, %{topic: queue_topic, milestone: 25}}
    assert queue_topic == topic(context.scope)
    assert_received {:event, %{topic: root_topic, milestone: 25}}
    assert root_topic == topic(root)
    assert MapSet.new(BuildProgress.facts(:all, server)) == MapSet.new([first, second])
    assert BuildProgress.facts(root, server) == [second]
    assert BuildProgress.facts({:queue, "absent"}, server) == []
  end

  test "corrupt, malformed and unreadable stores fail closed while facts and signals work", context do
    invalid_milestone = Jason.encode!(%{Jason.encode!(["queue", "id", 1]) => 26})

    for content <- ["not json", "[]", ~s({"bogus":25}), invalid_milestone] do
      File.write!(context.path, content)
      assert_disabled(context)
    end

    File.rm!(context.path)
    File.mkdir!(context.path)
    assert_disabled(context)
  end

  test "write failure suppresses milestones and stays disabled when storage recovers", context do
    server = start_store(context.path)
    File.mkdir!(context.path)
    :ok = BuildProgress.subscribe()
    fact = put(server, context.scope, 50)
    assert_received {:build_progress_changed, ^fact}
    assert BuildProgress.facts(context.scope, server) == [fact]
    refute_received {:event, %{topic: _}}
    File.rmdir!(context.path)
    put(server, context.scope, 100)
    refute_received {:event, %{topic: _}}
  end

  test "invalid facts cannot alter reads, signals or milestones; unknown percent is retained", context do
    server = start_store(context.path)
    :ok = BuildProgress.subscribe()
    fact = fact(context.scope, 100)

    for invalid <- [
          Map.delete(fact, :generation),
          %{fact | percent: 101},
          %{fact | percent: -1},
          %{fact | percent: "100"},
          %{fact | scope: {:other, "id"}},
          %{fact | generation: nil},
          %{fact | completed: -1},
          %{fact | resolved: 0},
          %{fact | total: 0},
          %{fact | observed_at: nil},
          %{fact | resolution: :bad},
          %{fact | freshness: :bad}
        ] do
      assert {:error, :invalid_fact} = BuildProgress.put_fact(invalid, server)
    end

    assert BuildProgress.facts(:all, server) == []
    refute_received {:build_progress_changed, _}
    refute_received {:event, %{topic: _}}
    unknown = put(server, context.scope, nil, resolution: :unknown, completed: nil, resolved: nil, total: nil)
    assert BuildProgress.facts(:all, server) == [unknown]
    assert_received {:build_progress_changed, ^unknown}
    refute_received {:event, %{topic: _}}
  end

  defp assert_disabled(context) do
    server = start_store(context.path)
    :ok = BuildProgress.subscribe()
    fact = put(server, context.scope, 80)
    assert BuildProgress.facts(context.scope, server) == [fact]
    assert_received {:build_progress_changed, ^fact}
    refute_received {:event, %{topic: _}}
    GenServer.stop(server)
  end

  defp start_store(path) do
    {:ok, server} = BuildProgress.start_link(name: nil, state_file: path)
    on_exit(fn -> Aiur.TestSupport.safe_stop(server) end)
    server
  end

  defp put(server, scope, percent, attrs \\ []) do
    fact = fact(scope, percent) |> Map.merge(Map.new(attrs))
    assert :ok = BuildProgress.put_fact(fact, server)
    fact
  end

  defp fact(scope, percent) do
    %{scope: scope, completed: 2, resolved: 4, total: 5, percent: percent, resolution: :resolved, generation: 1, observed_at: ~U[2026-10-07 12:00:00Z], freshness: :current}
  end

  defp topic({kind, id}), do: "system.#{kind}.#{id}.progress"
end

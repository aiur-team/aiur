defmodule Aiur.RunTelemetry.FactsCaptureTest do
  use ExUnit.Case, async: false
  alias Aiur.RunTelemetry.{Dataset, FactsCapture, Lifecycle, Writer}
  alias Aiur.RunTelemetry.Writer.Encoding

  setup do
    root = Aiur.TestSupport.tmp_root!("facts-capture")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{path: Path.join(root, "pending.json"), root: root}
  end

  defp worker(path, opts) do
    start_supervised!({FactsCapture, Keyword.merge([name: nil, path: path, interval: 60_000], opts)})
  end

  test "successful writer appends trigger one durable capture; completed merge dedupes after restart", %{path: path, root: root} do
    parent = self()

    opts = [
      enabled: fn -> true end,
      fetch: fn ticket ->
        send(parent, {:fetched, ticket})
        {:ok, %{approval_count: 1}}
      end,
      record: fn ticket, facts ->
        send(parent, {:facts, ticket, facts})
        :ok
      end
    ]

    pid = worker(path, opts)
    writer = start_supervised!({Writer, name: nil, path: Path.join(root, "telemetry.ndjson"), boot_id: "facts", facts_observer: &FactsCapture.observe(&1, pid)})
    attributes = %{ticket: "42", event: "pr_merged", boundary: "point"}
    Writer.record(writer, :lifecycle, attributes)
    Writer.record(writer, :lifecycle, attributes)
    Writer.flush(writer)
    assert_receive {:fetched, "42"}, 500
    assert_receive {:facts, "42", %{approval_count: 1}}, 500
    FactsCapture.drain(pid)
    stop_supervised!(FactsCapture)
    restarted = worker(path, opts)
    FactsCapture.capture("42", restarted)
    FactsCapture.drain(restarted)
    refute_receive {:fetched, "42"}, 500
    assert Jason.decode!(File.read!(path))["completed"] == ["42:merged", "42"]
  end

  test "budget holds retain attempts and queue survives restart", %{path: path} do
    parent = self()

    pid =
      worker(path,
        interval: 50,
        enabled: fn -> true end,
        fetch: fn _ ->
          send(parent, :held)
          {:error, {:aiur, :locally_held, %{}}}
        end
      )

    FactsCapture.capture("43", pid)
    assert_receive :held, 500
    wait_for_pending(path, "43", "next_at")
    assert Jason.decode!(File.read!(path))["pending"]["43"]["attempts"] == 0
    stop_supervised!(FactsCapture)

    worker(path,
      interval: 50,
      enabled: fn -> true end,
      fetch: fn _ ->
        send(parent, :resumed)
        {:ok, %{coverage: "available"}}
      end,
      record: fn _, _ -> :ok end
    )

    assert_receive :resumed, 500
  end

  test "three failures emit unavailable, disabled capture issues zero fetches", %{path: path} do
    parent = self()

    pid =
      worker(path,
        interval: 20,
        enabled: fn -> false end,
        fetch: fn _ ->
          send(parent, :unexpected)
          {:error, :timeout}
        end
      )

    FactsCapture.capture("45", pid)
    FactsCapture.drain(pid)
    refute_receive :unexpected, 500
    refute File.exists?(path)
    stop_supervised!(FactsCapture)

    pid =
      worker(path,
        interval: 20,
        enabled: fn -> true end,
        fetch: fn ticket ->
          send(parent, {:failure, ticket})
          {:error, :timeout}
        end,
        record: fn _, facts ->
          send(parent, {:unavailable, facts})
          :ok
        end
      )

    FactsCapture.capture("44", pid)
    assert_receive {:failure, "44"}, 500
    assert_receive {:failure, "44"}, 500
    assert_receive {:failure, "44"}, 500
    assert_receive {:unavailable, %{coverage: "unavailable"}}, 500
    refute_receive {:failure, "44"}, 500
  end

  test "facts lifecycle whitelists scalar facts and reducers preserve them", %{root: root} do
    path = Path.join(root, "facts.ndjson")
    writer = start_supervised!({Writer, name: nil, path: path, boot_id: "facts", facts_observer: fn _ -> :ok end})
    facts = %{pr_ready_at: "2026-10-09T00:01:00Z", approval_count: 1, reviewer_classes: ["trusted"], body: "private", login: "private"}
    Lifecycle.record("46", nil, :pr_facts, :point, facts, recorder: &Writer.record_sync(writer, &1, &2, &3))
    {:ok, dataset} = Dataset.build(path)
    result = dataset.tickets["46"].pr_facts
    assert result["pr_ready_at"] == facts.pr_ready_at
    assert result["approval_count"] == 1
    assert result["reviewer_classes"] == ["trusted"]
    refute Map.has_key?(result, "body")
    refute Map.has_key?(result, "login")
  end

  test "a closed ticket with an open PR can later capture its merge", %{path: path} do
    parent = self()

    pid =
      worker(path,
        enabled: fn -> true end,
        fetch: fn ticket ->
          send(parent, {:queried, ticket})
          {:ok, %{merged_at: nil}}
        end,
        record: fn _, _ -> :ok end
      )

    FactsCapture.capture("47", pid)
    assert_receive {:queried, "47"}, 500
    wait_for_completed(path, "47")
    FactsCapture.observe(%{event: "pr_merged", ticket: "47"}, pid)
    assert_receive {:queried, "47"}, 500
    wait_for_completed(path, "47:merged")
    FactsCapture.observe(%{event: "pr_merged", ticket: "47"}, pid)
    FactsCapture.drain(pid)
    refute_receive {:queried, "47"}, 500
  end

  test "overlapping terminal and merge triggers coalesce once merged facts arrive", %{path: path} do
    parent = self()

    pid =
      worker(path,
        enabled: fn -> true end,
        fetch: fn ticket ->
          send(parent, {:started, ticket, self()})

          receive do
            :release -> {:ok, %{merged_at: "2026-10-09T00:05:00Z"}}
          after
            1_000 -> {:error, :test_timeout}
          end
        end,
        record: fn _, _ -> :ok end
      )

    FactsCapture.capture("48", pid)
    assert_receive {:started, "48", task}, 500
    FactsCapture.observe(%{event: "pr_merged", ticket: "48"}, pid)
    FactsCapture.drain(pid)
    send(task, :release)
    wait_for_completed(path, "48:merged")
    FactsCapture.drain(pid)
    refute_receive {:started, "48", _}, 500
    assert Jason.decode!(File.read!(path))["pending"] == %{}
  end

  test "a later merge snapshot survives segment continuation", %{root: root} do
    first = Lifecycle.facts_attributes("49", %{pr_number: 90, pr_ready_at: "2026-10-09T00:01:00Z"})
    merged = Lifecycle.facts_attributes("49", %{pr_number: 90, merged_at: "2026-10-09T00:05:00Z"})
    carried = Encoding.track_carried_points(%{}, [{:lifecycle, first, "2026-10-09T00:02:00Z"}, {:lifecycle, merged, "2026-10-09T00:06:00Z"}])
    path = Path.join(root, "continued.ndjson")
    writer = start_supervised!({Writer, name: nil, path: path, boot_id: "continued", facts_observer: fn _ -> :ok end})
    Enum.each(Encoding.carried_point_records(carried), fn {kind, attrs, timestamp} -> Writer.record_sync(writer, kind, attrs, timestamp: timestamp) end)
    {:ok, dataset} = Dataset.build(path)
    assert dataset.tickets["49"].pr_facts["merged_at"] == "2026-10-09T00:05:00Z"
  end

  test "an unreadable pending queue is preserved without issuing requests", %{path: path} do
    parent = self()
    bytes = "{unfinished"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    pid =
      worker(path,
        enabled: fn -> true end,
        fetch: fn _ ->
          send(parent, :unexpected_read)
          {:ok, %{}}
        end
      )

    FactsCapture.capture("50", pid)
    FactsCapture.drain(pid)
    refute_receive :unexpected_read, 500
    assert File.read!(path) == bytes
  end

  defp wait_for_completed(path, ticket, remaining \\ 100) do
    if ticket in Jason.decode!(File.read!(path))["completed"] do
      :ok
    else
      assert remaining > 0
      Process.sleep(5)
      wait_for_completed(path, ticket, remaining - 1)
    end
  end

  defp wait_for_pending(path, ticket, key, remaining \\ 100) do
    stored = Jason.decode!(File.read!(path))

    if get_in(stored, ["pending", ticket, key]) do
      :ok
    else
      assert remaining > 0
      Process.sleep(5)
      wait_for_pending(path, ticket, key, remaining - 1)
    end
  end
end

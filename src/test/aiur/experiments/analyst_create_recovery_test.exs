defmodule Aiur.Experiments.AnalystCreateRecoveryTest do
  use Aiur.TestSupport
  alias Aiur.Experiments
  alias Aiur.Experiments.{AnalysisTicket, Analyst, Store}
  alias Aiur.GitHub.IssueLookup

  setup do
    root = Aiur.TestSupport.tmp_root!("analyst-create-recovery")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    start_supervised!(Store)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    attrs = %{
      title: "Create recovery",
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: DateTime.to_iso8601(DateTime.utc_now())}},
      metrics: [%{ref: "delivery-speed/start_to_merge"}]
    }

    {:ok, spec} = Experiments.create(attrs, freeze: false)
    %{id: spec.id, clock: :atomics.new(1, [])}
  end

  test "restart after creating journal but before POST waits then resends the same durable request", %{id: id, clock: clock} do
    started = System.system_time(:millisecond) - 4 * 86_400_000
    :atomics.put(clock, 1, started)
    pending = crash_before_post(id, clock)
    since = DateTime.from_unix!(started - 300_000, :millisecond) |> DateTime.to_iso8601()
    pid = start_analyst(clock, find: lookup(large_repository(since)))

    assert {:error, :ticket_retry_pending} = Experiments.analyze(id, mode: "spec")
    retry(pid)
    refute_received {:lookup, _}
    refute_received {:post, _}

    :atomics.put(clock, 1, started + 4 * 86_400_000)
    retry(pid)
    marker = AnalysisTicket.marker(pending)
    assert_received {:lookup, ^marker}
    assert_received {:labels, ["agent:todo", "complexity:2", "experiment-analysis"]}
    assert_received {:post, attrs}
    assert attrs.body =~ marker
    assert {:ok, [recovered]} = Experiments.analysis_requests(id)
    assert recovered["request_id"] == pending["request_id"]
    assert recovered["nonce"] == pending["nonce"]
    assert recovered["first_creating_ms"] == started
    assert {:ok, immutable} = Experiments.update_analysis_dispatch(id, recovered["request_id"], %{"first_creating_ms" => started + 60_000})
    assert immutable["first_creating_ms"] == started
    assert recovered["ticket"]["number"] == 42
    retry(pid)
    refute_received {:post, _}
  end

  test "resend after supersession uses the current brief and records the newly dispatched type", %{id: id, clock: clock} do
    pending = crash_before_post(id, clock, mode: "report")
    pid = start_analyst(clock)
    assert {:error, :ticket_retry_pending} = Experiments.analyze(id, mode: "report", analysis_type: "confirmatory")
    :atomics.put(clock, 1, 60_000)
    retry(pid)

    assert_received {:labels, ["agent:todo", "complexity:3", "experiment-analysis"]}
    assert_received {:post, attrs}
    assert attrs.body =~ AnalysisTicket.marker(pending)
    assert attrs.body =~ "stored confirmatory report"
    assert {:ok, [recovered]} = Experiments.analysis_requests(id)
    assert recovered["request_id"] == pending["request_id"]
    assert recovered["dispatched_analysis_type"] == "confirmatory"
    assert recovered["ticket"]["analysis_type"] == "confirmatory"
    refute_received {:promoted, _}
  end

  test "legacy uncertain requests use original request time rather than a recent retry cutoff", %{id: id, clock: clock} do
    assert {:ok, pending} = Experiments.request_analysis(id, "spec", [])
    assert {:ok, _} = Experiments.update_analysis_dispatch(id, pending["request_id"], %{"dispatch_requested" => true, "ticket_status" => "uncertain"})
    {:ok, requested, _} = DateTime.from_iso8601(pending["requested_at"])
    since = requested |> DateTime.to_unix(:millisecond) |> Kernel.-(300_000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    :atomics.put(clock, 1, DateTime.to_unix(requested, :millisecond) + 86_400_000)
    start_analyst(clock, find: lookup(large_repository(since)))

    assert {:ok, %{"ticket" => %{"number" => 42}, "request" => recovered}} = Experiments.analyze(id, mode: "spec")
    refute Map.has_key?(recovered, "first_creating_ms")
    assert recovered["nonce"] == pending["nonce"]
  end

  # Future regression guard: adopting an existing ticket must preserve the pre-existing promotion path.
  test "finding an existing ticket after supersession retains its original dispatch type", %{id: id, clock: clock} do
    start_analyst(clock, create: fn _ -> {:error, :timeout} end)
    assert {:error, :timeout} = Experiments.analyze(id, mode: "report")
    assert {:ok, [pending]} = Experiments.analysis_requests(id)
    assert pending["ticket_status"] == "uncertain"
    stop_supervised!(Analyst)
    find = lookup(fn _ -> {:ok, %{status: 200, body: [%{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42", "body" => AnalysisTicket.marker(pending)}]}} end)
    pid = start_analyst(clock, find: find)
    assert {:error, :ticket_retry_pending} = Experiments.analyze(id, mode: "report", analysis_type: "confirmatory")
    :atomics.put(clock, 1, 60_000)
    retry(pid)

    assert {:ok, [recovered]} = Experiments.analysis_requests(id)
    assert recovered["dispatched_analysis_type"] == "interim"
    assert recovered["ticket"]["analysis_type"] == "interim"
    assert recovered["routing_promoted"] == true
    assert_received {:promoted, 42}
    refute_received {:post, _}
  end

  # Future regression guard: errors already blocked resends before complete absence became retryable.
  test "incomplete, failed and ambiguous reconciliation cannot authorize another POST", %{id: id, clock: clock} do
    pending = crash_before_post(id, clock)
    next = [{"link", "<https://api.github.com/repos/owner/repo/issues?page=2>; rel=\"next\""}]
    issue = %{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42", "body" => AnalysisTicket.marker(pending)}

    for {response, reason, at} <- [
          {{:ok, %{status: 200, body: [], headers: next}}, :incomplete_issue_lookup, 60_000},
          {{:error, :timeout}, :timeout, 180_000},
          {{:ok, %{status: 200, body: [issue, issue]}}, :ambiguous_issue_lookup, 420_000}
        ] do
      start_analyst(clock, find: lookup(fn _ -> response end))
      :atomics.put(clock, 1, at)
      assert {:error, ^reason} = Experiments.analyze(id, mode: "spec")
      stop_supervised!(Analyst)
      refute_received {:labels, _}
      refute_received {:post, _}
      assert {:ok, [request]} = Experiments.analysis_requests(id)
      assert request["ticket_status"] == "uncertain"
      assert request["request_id"] == pending["request_id"]
      assert request["ticket"] == nil
    end
  end

  defp crash_before_post(id, clock, opts \\ []) do
    pid = start_analyst(clock, labels: fn _ -> Process.exit(self(), :kill) end)
    monitor = Process.monitor(pid)
    catch_exit(Experiments.analyze(id, Keyword.put_new(opts, :mode, "spec")))
    assert_received {:DOWN, ^monitor, :process, ^pid, :killed}
    refute_received {:post, _}
    stop_supervised(Analyst)
    stop_supervised!(Store)
    start_supervised!(Store)
    assert {:ok, [pending]} = Experiments.analysis_requests(id)
    assert pending["ticket_status"] == "creating"
    assert pending["dispatch_attempts"] == 1
    assert pending["next_attempt_ms"] == :atomics.get(clock, 1) + 60_000
    pending
  end

  defp start_analyst(clock, opts \\ []) do
    parent = self()

    defaults = [
      start_paused?: true,
      clock: fn -> :atomics.get(clock, 1) end,
      find: lookup(fn _ -> {:ok, %{status: 200, body: []}} end),
      labels: fn labels ->
        send(parent, {:labels, labels})
        :ok
      end,
      promote: fn number ->
        send(parent, {:promoted, number})
        :ok
      end,
      create: fn attrs ->
        send(parent, {:post, attrs})
        {:ok, %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}}
      end
    ]

    start_supervised!(Supervisor.child_spec({Analyst, Keyword.merge(defaults, opts)}, restart: :temporary))
  end

  defp large_repository(since) do
    {:ok, cutoff, _offset} = DateTime.from_iso8601(since)
    updated = DateTime.utc_now() |> DateTime.to_iso8601()
    rows = for number <- 1..1100, do: %{"number" => number, "body" => "old history", "created_at" => cutoff |> DateTime.add(-number, :second) |> DateTime.to_iso8601(), "updated_at" => updated}

    fn request ->
      query = URI.decode_query(URI.parse(request.url).query)
      page = String.to_integer(query["page"] || "1")
      filter = if query["since"], do: DateTime.from_iso8601(query["since"]) |> elem(1)
      eligible = Enum.filter(rows, fn row -> is_nil(filter) or DateTime.compare(DateTime.from_iso8601(row["updated_at"]) |> elem(1), filter) == :gt end)
      ordered = Enum.sort_by(eligible, & &1["created_at"], :desc)
      body = Enum.slice(ordered, (page - 1) * 100, 100)
      next = URI.parse(request.url) |> Map.put(:query, URI.encode_query(Map.put(query, "page", page + 1))) |> URI.to_string()
      headers = if length(ordered) > page * 100, do: [{"link", "<#{next}>; rel=\"next\""}], else: []
      {:ok, %{status: 200, body: body, headers: headers}}
    end
  end

  defp lookup(request) do
    parent = self()

    fn marker, opts ->
      send(parent, {:lookup, marker})
      IssueLookup.find(marker, Keyword.merge(opts, token: "fixture-token", request_fun: request))
    end
  end

  defp retry(pid) do
    send(pid, :retry)
    :sys.get_state(pid)
  end
end

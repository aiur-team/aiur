defmodule Aiur.Experiments.AnalysisRequestsTest do
  use ExUnit.Case, async: false

  alias Aiur.Experiments
  alias Aiur.Experiments.{AnalysisRequests, Journal, Paths, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "analysis-requests-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    :ok = Aiur.TestSupport.ensure_pubsub_running()

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    start_supervised!(Store)

    attrs = %{
      title: "Analysis requests",
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-01T00:00:00Z"}},
      metrics: [%{ref: "delivery-speed/start_to_merge", direction: "decrease"}]
    }

    {:ok, experiment} = Experiments.create(attrs, freeze: false)
    %{id: experiment.id}
  end

  test "concurrent duplicate triggers create one durable open request, including after restart", %{id: id} do
    results =
      1..12
      |> Task.async_stream(fn _ -> Experiments.request_analysis(id, "spec", trigger: "created", requested_by: "daemon") end, max_concurrency: 4)
      |> Enum.map(fn {:ok, {:ok, request}} -> request end)

    assert [request] = Enum.uniq(results)
    assert request["state"] == "open"
    assert request["requested_by"] == "daemon"
    assert request["ticket"] == nil
    assert Regex.match?(~r/^[0-9a-f]{32}$/, request["nonce"])
    assert {:ok, [^request]} = AnalysisRequests.history(id)
    stop_supervised!(Store)
    start_supervised!(Store)
    assert {:ok, ^request} = Experiments.request_analysis(id, "spec", trigger: "created")
    assert {:ok, [^request]} = Experiments.analysis_requests(id)
  end

  test "confirmatory supersedes interim without changing identity or creating another ticket", %{id: id} do
    {:ok, interim} = Experiments.request_analysis(id, "report", trigger: "sample_guard_met", reason: "guard")
    ticket = %{"number" => 42, "url" => "https://github.com/example/repo/issues/42"}
    assert {:ok, attached} = Experiments.attach_analysis_ticket(id, interim["request_id"], ticket)
    assert attached["ticket"] == ticket

    assert {:ok, confirmatory} = Experiments.request_analysis(id, "report", analysis_type: "confirmatory", trigger: "planned_n_met", reason: "planned n")
    assert confirmatory["request_id"] == interim["request_id"]
    assert confirmatory["nonce"] == interim["nonce"]
    assert confirmatory["ticket"] == ticket
    assert confirmatory["analysis_type"] == "confirmatory"
    assert confirmatory["superseded_reason"] == "planned n"
    assert confirmatory["revision"] == 3
    assert confirmatory["triggers"] == ["sample_guard_met", "planned_n_met"]
    assert {:ok, ^confirmatory} = Experiments.request_analysis(id, "report")
    assert {:ok, ^confirmatory} = Experiments.request_analysis(id, "spec")
    assert {:ok, ^confirmatory} = Experiments.request_analysis(id, "report", trigger: "sample_guard_met")
    assert {:ok, [^confirmatory]} = Experiments.analysis_requests(id)
    assert {:ok, [^interim, ^attached, ^confirmatory]} = AnalysisRequests.history(id)
  end

  test "a matching submission fulfills once; a completed trigger never opens another request", %{id: id} do
    {:ok, request} = Experiments.request_analysis(id, "report", analysis_type: "confirmatory", trigger: "planned_n_met")
    request_id = request["request_id"]
    interim = %{"mode" => "report", "analysis_type" => "interim", "version" => 1}
    assert {:error, :submission_mismatch} = Experiments.fulfill_analysis_request(id, request_id, interim)
    assert {:error, :submission_mismatch} = Experiments.fulfill_analysis_request(id, request_id, %{"mode" => "spec", "version" => 1})
    assert {:ok, [^request]} = AnalysisRequests.history(id)

    submission = Map.put(interim, "analysis_type", "confirmatory")
    assert {:ok, fulfilled} = Experiments.fulfill_analysis_request(id, request_id, submission)
    assert fulfilled["state"] == "fulfilled"
    assert fulfilled["submission"] == submission
    assert {:ok, ^fulfilled} = Experiments.fulfill_analysis_request(id, request_id, submission)
    assert {:ok, ^fulfilled} = Experiments.request_analysis(id, "report", analysis_type: "confirmatory", trigger: "planned_n_met")
    assert {:ok, [^request, ^fulfilled]} = AnalysisRequests.history(id)
    assert {:ok, next} = Experiments.request_analysis(id, "report")
    refute next["request_id"] == request_id
    assert next["state"] == "open"
  end

  test "spec can advance to report; cancellation preserves history and rejects stale fulfillment", %{id: id} do
    {:ok, spec} = Experiments.request_analysis(id, "spec")
    assert {:ok, report} = Experiments.request_analysis(id, "report", trigger: "sample_guard_met")
    assert report["mode"] == "report"
    assert report["analysis_type"] == "interim"
    assert report["request_id"] == spec["request_id"]
    assert {:ok, cancelled} = Experiments.cancel_analysis_request(id, spec["request_id"], "Executor takeover")
    assert cancelled["state"] == "cancelled"
    assert cancelled["cancel_reason"] == "Executor takeover"
    assert {:error, :request_closed} = Experiments.fulfill_analysis_request(id, spec["request_id"], %{"mode" => "report", "analysis_type" => "interim", "version" => 1})
    assert {:ok, ^cancelled} = Experiments.request_analysis(id, "report", trigger: "sample_guard_met")
    assert {:ok, next} = Experiments.request_analysis(id, "spec", requested_by: "local")
    refute next["request_id"] == spec["request_id"]
    assert {:ok, [^spec, ^report, ^cancelled, ^next]} = AnalysisRequests.history(id)
  end

  test "unknown experiments, invalid requests and future journals fail without writes", %{id: id} do
    assert {:error, :not_found} = Experiments.request_analysis("unknown-experiment", "spec")
    assert {:error, :not_found} = Experiments.request_analysis("../../outside", "spec")
    assert {:error, :invalid_analysis_request} = Experiments.request_analysis(id, "unknown")
    assert {:error, :invalid_analysis_request} = Experiments.request_analysis(id, "report", analysis_type: "guess")
    assert {:error, :invalid_analysis_request} = Experiments.request_analysis(id, "spec", trigger: %{})
    refute File.exists?(Paths.file(id, "requests.ndjson"))

    path = Paths.file(id, "requests.ndjson")
    future = Jason.encode!(%{schema_version: 2, state: "open"}) <> "\n"
    File.write!(path, future)
    assert {:error, {:newer_version, 2}} = Experiments.request_analysis(id, "spec")
    assert File.read!(path) == future

    malformed = Jason.encode!(%{schema_version: 1, state: "open"}) <> "\n"
    File.write!(path, malformed)
    assert {:error, :invalid_analysis_journal} = Experiments.request_analysis(id, "spec")
    assert File.read!(path) == malformed
  end

  test "ticket association is idempotent and never replaces an existing ticket", %{id: id} do
    {:ok, request} = Experiments.request_analysis(id, "spec")
    ticket = %{"number" => 42, "url" => "https://github.com/example/repo/issues/42"}
    assert {:ok, attached} = Experiments.attach_analysis_ticket(id, request["request_id"], ticket)
    assert {:ok, ^attached} = Experiments.attach_analysis_ticket(id, request["request_id"], ticket)
    assert {:error, :ticket_exists} = Experiments.attach_analysis_ticket(id, request["request_id"], Map.put(ticket, "number", 43))
    assert {:error, :invalid_ticket} = Experiments.attach_analysis_ticket(id, request["request_id"], %{"number" => -1, "url" => "bad"})
    assert {:error, :request_not_found} = Experiments.attach_analysis_ticket(id, "missing", ticket)
    assert {:ok, [^request, ^attached]} = Journal.read(Paths.file(id, "requests.ndjson"))
  end
end

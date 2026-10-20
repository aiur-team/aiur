defmodule Aiur.Experiments.AnalystTicketLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.Experiments
  alias Aiur.Experiments.{Analyst, Paths, Store}
  alias Aiur.GitHub.{OpenIssueListing, OpenIssueSnapshot}

  setup do
    root = Aiur.TestSupport.tmp_root!("analyst-ticket-lifecycle")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    start_supervised!(Store)
    unless Process.whereis(OpenIssueSnapshot), do: start_supervised!(OpenIssueSnapshot)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    attrs = %{
      title: "Analyst lifecycle #{System.unique_integer([:positive])}",
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: DateTime.to_iso8601(DateTime.utc_now())}},
      metrics: [%{ref: "delivery-speed/start_to_merge"}]
    }

    {:ok, spec} = Experiments.create(attrs, freeze: false)
    %{id: spec.id}
  end

  defp analyst(id, opts \\ []) do
    parent = self()

    defaults = [
      start_paused?: true,
      open_tickets: fn ->
        send(parent, :snapshot_read)
        OpenIssueSnapshot.fetch_labels("analyst-lifecycle-test", id, 120_000)
      end,
      labels: fn _ -> :ok end,
      create: fn _ ->
        send(parent, :created)
        {:ok, %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}}
      end,
      alert: fn request -> send(parent, {:alert, request}) end
    ]

    start_supervised!({Analyst, Keyword.merge(defaults, opts)})
  end

  defp tick(pid) do
    send(pid, :retry)
    :sys.get_state(pid)
  end

  # Terminal-state fixtures predate their observation by a full second without sleeping.
  # The race regression below uses actual attachment timestamps and never edits the journal.
  defp age_request(id) do
    path = Paths.file(id, "requests.ndjson")
    at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    rows = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&(Jason.decode!(&1) |> Map.put("at", at)))
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
  end

  defp snapshot(id, labels, age? \\ true) do
    if age?, do: age_request(id)
    OpenIssueSnapshot.put("analyst-lifecycle-test", id, Map.keys(labels), labels, DateTime.utc_now())
  end

  test "closed ticket fails durably once, preserves trigger receipt, and frees the manual request slot", %{id: id} do
    pid = analyst(id)
    assert {:ok, original} = Experiments.analyze(id, mode: "spec", trigger: "created")
    assert_received :created
    snapshot(id, %{})
    tick(pid)
    assert_received :snapshot_read
    refute_received :snapshot_read
    assert_received {:alert, failed}
    assert failed["state"] == "failed"
    assert failed["failure_reason"] == "analysis_ticket_closed_without_submission"
    refute Map.has_key?(failed, "submission")
    assert {:ok, [^failed]} = Experiments.analysis_requests(id)
    tick(pid)
    refute_received {:alert, _}
    stop_supervised!(Store)
    start_supervised!(Store)
    assert {:ok, [^failed]} = Experiments.analysis_requests(id)
    assert {:ok, replay} = Experiments.analyze(id, mode: "spec", trigger: "created")
    assert replay["request"] == failed
    refute_received :created
    assert {:ok, next} = Experiments.analyze(id, mode: "spec")
    assert next["request"]["state"] == "open"
    refute next["request"]["request_id"] == original["request"]["request_id"]
    assert_received :created
  end

  for label <- ["agent:done", "agent:error"] do
    test "#{label} without submission fails an open ticket", %{id: id} do
      pid = analyst(id)
      assert {:ok, _} = Experiments.analyze(id, mode: "spec")
      snapshot(id, %{"42" => %{labels: [unquote(label)], updated_at: nil}})
      tick(pid)
      assert_received {:alert, failed}
      assert failed["state"] == "failed"
      assert failed["failure_reason"] == "analysis_ticket_#{String.replace(unquote(label), "agent:", "")}_without_submission"
      refute Map.has_key?(failed, "submission")
      tick(pid)
      refute_received {:alert, _}
    end
  end

  test "absent, stale and pre-attachment snapshots cannot close a new request", %{id: id} do
    pid = analyst(id)
    assert {:ok, _} = Experiments.analyze(id, mode: "spec")
    tick(pid)
    assert {:ok, [open]} = Experiments.analysis_requests(id)
    assert open["state"] == "open"
    {:ok, at, _} = DateTime.from_iso8601(open["at"])

    for observed_at <- [System.system_time(:millisecond) - 120_001, DateTime.to_unix(at, :millisecond) - 1] do
      snapshot(id, %{}, false)
      :ets.update_element(OpenIssueSnapshot, {:labels, "analyst-lifecycle-test/#{id}"}, {3, observed_at})
      tick(pid)
      assert {:ok, [^open]} = Experiments.analysis_requests(id)
      refute_received {:alert, _}
    end
  end

  for timing <- [:before_attachment, :same_millisecond] do
    test "a #{timing} listing cannot fail a healthy request after it completes", %{id: id} do
      pid = analyst(id)
      before_attach = DateTime.add(DateTime.utc_now(), -1, :second)
      assert {:ok, result} = Experiments.analyze(id, mode: "spec")
      {:ok, attached_at, _} = DateTime.from_iso8601(result["request"]["at"])
      listed_from = if unquote(timing) == :before_attachment, do: before_attach, else: DateTime.truncate(attached_at, :millisecond)
      assert :ok = OpenIssueListing.record("analyst-lifecycle-test", id, [], listed_from)
      assert {:ok, cached_labels, cached_from} = OpenIssueSnapshot.fetch_labels("analyst-lifecycle-test", id, 120_000)
      assert cached_labels == %{}
      assert cached_from == DateTime.to_unix(listed_from, :millisecond)
      tick(pid)
      assert {:ok, [open]} = Experiments.analysis_requests(id)
      assert open["state"] == "open"
      refute_received {:alert, _}
      persist_submission_without_receipt(id)
      tick(pid)
      assert {:ok, [fulfilled]} = Experiments.analysis_requests(id)
      assert fulfilled["state"] == "fulfilled"
      assert fulfilled["submission"] == %{"mode" => "spec", "version" => 1}
    end
  end

  # Future regression guard: a trustworthy observation must retain normal closure detection.
  test "a later complete listing still detects a ticket closed without submission", %{id: id} do
    pid = analyst(id)
    assert {:ok, _} = Experiments.analyze(id, mode: "spec")
    age_request(id)
    assert :ok = OpenIssueListing.record("analyst-lifecycle-test", id, [], DateTime.utc_now())
    tick(pid)
    assert {:ok, [failed]} = Experiments.analysis_requests(id)
    assert failed["state"] == "failed"
    assert failed["failure_reason"] == "analysis_ticket_closed_without_submission"
    assert_received {:alert, ^failed}
  end

  test "active ticket remains open and local request never closes from a listing", %{id: id} do
    pid = analyst(id)
    assert {:ok, local} = Experiments.analyze(id, mode: "spec", local: true)
    snapshot(id, %{})
    tick(pid)
    assert {:ok, [local_request]} = Experiments.analysis_requests(id)
    assert local_request["request_id"] == local["request"]["request_id"]
    assert local_request["state"] == "open"
    assert {:ok, _} = Experiments.analyze(id, mode: "spec")
    snapshot(id, %{"42" => %{labels: ["agent:in-progress"], updated_at: nil}})
    tick(pid)
    assert {:ok, [open]} = Experiments.analysis_requests(id)
    assert open["state"] == "open"
    refute_received {:alert, _}
  end

  test "persisted submission is recovered before terminal ticket failure", %{id: id} do
    pid = analyst(id)
    assert {:ok, _} = Experiments.analyze(id, mode: "spec")
    persist_submission_without_receipt(id)
    snapshot(id, %{})
    tick(pid)
    assert {:ok, [fulfilled]} = Experiments.analysis_requests(id)
    assert fulfilled["state"] == "fulfilled"
    assert fulfilled["submission"] == %{"mode" => "spec", "version" => 1}
    refute_received {:alert, _}
  end

  test "serialized failure rechecks persisted submissions before changing state", %{id: id} do
    assert {:ok, request} = Experiments.request_analysis(id, "spec")
    persist_submission_without_receipt(id)
    assert {:error, :request_closed} = Experiments.fail_analysis_request(id, request["request_id"], "analysis_ticket_closed_without_submission")
    assert {:ok, [fulfilled]} = Experiments.analysis_requests(id)
    assert fulfilled["state"] == "fulfilled"
    assert fulfilled["submission"] == %{"mode" => "spec", "version" => 1}
    refute Map.has_key?(fulfilled, "failure_reason")
  end

  defp persist_submission_without_receipt(id) do
    path = Paths.file(id, "requests.ndjson")
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)

    registration =
      Path.expand("../../fixtures/experiments/preregistration.valid.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("experiment_id", id)
      |> Map.put("registered_at", DateTime.to_iso8601(DateTime.utc_now()))

    assert {:error, :eisdir} = Experiments.put_preregistration(id, registration)
    File.rmdir!(path)
    File.rename!(path <> ".saved", path)
  end
end

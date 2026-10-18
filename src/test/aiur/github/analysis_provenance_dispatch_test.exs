defmodule Aiur.GitHub.AnalysisProvenanceDispatchTest do
  use ExUnit.Case, async: false
  import Aiur.GitHub.DispatchAuthorization.TestFixtures
  alias Aiur.Experiments
  alias Aiur.Experiments.{AnalysisTicket, Analyst, Paths, Store}
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.Tracker.DispatchProvenance

  setup do
    root = Aiur.TestSupport.tmp_root!("analysis-provenance-dispatch")
    previous = for key <- [:experiments_dir, :dispatch_provenance], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :experiments_dir, root)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    start_supervised!(Store)
    DispatchAuthorization.clear_cache()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      DispatchAuthorization.clear_cache()
      Aiur.TestCleanup.rm_rf!(root)
    end)

    attrs = %{
      title: "Dispatch",
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: DateTime.utc_now() |> DateTime.to_iso8601()}},
      metrics: [%{ref: "delivery-speed/start_to_merge"}]
    }

    {:ok, spec} = Experiments.create(attrs, freeze: false)

    start_supervised!(
      {Analyst, start_paused?: true, daemon_account: fn -> "daemon[bot]" end, labels: fn _ -> :ok end, create: fn _ -> {:ok, %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}} end}
    )

    {:ok, result} = Experiments.analyze(spec.id, mode: "spec")
    request = result["request"]
    issue = issue(creator_login: "daemon[bot]", description: AnalysisTicket.marker(request), url: request["ticket"]["url"], labels: ["experiment-analysis"])
    %{issue: issue, request: request, id: spec.id}
  end

  defp authorize(issue, actors \\ ["daemon[bot]"]) do
    events = actors |> Enum.with_index(1) |> Enum.map(fn {actor, index} -> labeled_event(index, "agent:todo", actor, "2026-01-01T00:00:00Z") end)
    authorize_with_events(issue, events, ["operator"], daemon_account: "daemon[bot]", bot_account: "agent-bot")
  end

  test "real filing persists identity and dispatches through the registered store hook", %{issue: issue, request: request} do
    assert request["daemon_login"] == "daemon[bot]"
    assert authorize(issue).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    assert authorize(issue, ["daemon[bot]", "agent-bot"]).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    events = [labeled_event(1, "agent:todo", "daemon[bot]", "2026-01-01T00:00:00Z"), labeled_event(2, "agent:in-progress", "agent-bot", "2026-01-01T00:00:00Z")]
    active = %{issue | state: "in-progress", state_labels: ["agent:in-progress"]}
    assert authorize_with_events(active, events, ["operator"], daemon_account: "daemon[bot]", bot_account: "agent-bot").dispatch_authorized?
    DispatchAuthorization.clear_cache()
    refute authorize_with_events(active, events, ["operator"], daemon_account: "replacement[bot]", bot_account: "agent-bot").dispatch_authorized?
  end

  test "local request closure revokes authorization despite a cached verified timeline", %{issue: issue, request: request, id: id} do
    assert authorize(issue).dispatch_authorized?
    assert {:ok, _cancelled} = Experiments.cancel_analysis_request(id, request["request_id"], "cancelled")
    refute authorize(issue).dispatch_authorized?
  end

  test "outsider or missing actor anywhere in state-label history denies the fallback", %{issue: issue} do
    assert authorize(issue).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    refute authorize(issue, ["outsider", "daemon[bot]"]).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    refute authorize(issue, ["daemon[bot]", "outsider"]).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    refute authorize(issue, [nil, "daemon[bot]"]).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    events = [labeled_event(1, "agent:todo", "daemon[bot]", "2026-01-01T00:00:00Z"), Map.put(labeled_event(2, "agent:paused", "outsider", "2026-01-01T00:00:00Z"), "event", "unlabeled")]
    refute authorize_with_events(issue, events, ["operator"], daemon_account: "daemon[bot]", bot_account: "agent-bot").dispatch_authorized?
  end

  test "copied or edited marker and missing local records never grant trust", %{issue: issue, id: id} do
    assert authorize(issue).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    refute authorize(%{issue | creator_login: "outsider"}).dispatch_authorized?
    refute authorize(%{issue | id: "43"}).dispatch_authorized?
    refute authorize(%{issue | description: String.replace(issue.description, "nonce=", "nonce=0")}).dispatch_authorized?
    File.write!(Paths.file(id, "requests.ndjson"), "corrupt journal\n")
    refute authorize(issue).dispatch_authorized?
    Application.put_env(:aiur, :experiments_dir, Path.join(Application.fetch_env!(:aiur, :experiments_dir), "absent"))
    refute authorize(issue).dispatch_authorized?
  end

  test "absent or dead hook leaves normal human triage unchanged", %{issue: issue} do
    assert authorize(issue).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    Application.delete_env(:aiur, :dispatch_provenance)
    refute authorize(issue).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    assert authorize_with_events(issue, [labeled_event(1, "agent:todo", "operator", "2026-01-01T00:00:00Z")], ["operator"]).dispatch_authorized?
    DispatchAuthorization.clear_cache()
    pid = spawn(fn -> DispatchProvenance.register(fn _ -> true end) end)
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    end

    refute authorize(issue).dispatch_authorized?
  end
end

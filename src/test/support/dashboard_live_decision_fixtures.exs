defmodule AiurWeb.DashboardLiveSupport.DecisionFixtures do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import AiurWeb.DashboardLiveSupport, only: [eventually: 2, restore_application_env: 2]

  alias Aiur.{Decision, DecisionStore}
  alias AiurWeb.DashboardLiveSupport.StoreStubs.{StaleDetailStore, VersionedDetailStore}

  def request_api_decision(store, source_id, authority, opts \\ []) do
    assert {:ok, %{decision: decision}} =
             Aiur.DecisionStoreCase.request(
               store,
               %{
                 "source_id" => source_id,
                 "question" => "Choose #{source_id}?",
                 "blocking" => true,
                 "kind" => "architecture",
                 "authority" => Atom.to_string(authority),
                 "reversibility" => "reversible"
               },
               Keyword.merge(
                 [
                   ticket: %{identifier: "AIUR-984", title: "Supervisor decision API", url: nil},
                   source: %{agent_id: "agent-984", session_id: "session-984", event_id: "event-#{source_id}"}
                 ],
                 opts
               )
             )

    decision
  end

  def request_queue_decision(store, source_id, identifier, opts \\ []) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => source_id,
                 "question" => Aiur.DecisionStoreCase.question_with_identity("Should the dashboard ship this change?", source_id),
                 "blocking" => true,
                 "urgency" => "critical",
                 "reversibility" => "reversible",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               },
               Keyword.merge(
                 [
                   ticket: %{identifier: identifier, title: "Operator Control Center", url: nil},
                   source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-#{source_id}"}
                 ],
                 opts
               ),
               store
             )

    decision
  end

  def supervisor_api_opts(store) do
    [
      store: store,
      policy: %{allowed_kinds: ["architecture"], allow_non_reversible: false},
      actor: %{kind: :supervisor, id: "supervising-agent"}
    ]
  end

  def supervisor_decision_payload(expected_version) do
    %{
      "idempotency_key" => "dashboard-supervisor-decision",
      "expected_version" => expected_version,
      "custom_response" => "Use the canonical path",
      "rationale" => "It preserves one append-only lifecycle.",
      "confidence" => 91,
      "alternatives_considered" => ["Wait for more evidence"],
      "reversibility_belief" => "reversible"
    }
  end

  def supervisor_revision_payload(action_id, expected_version) do
    %{
      "expected_version" => expected_version,
      "expected_action_id" => action_id,
      "expected_revision_sequence" => 0,
      "idempotency_key" => "dashboard-supervisor-revision",
      "custom_response" => "Use the corrected path",
      "rationale" => "New production evidence",
      "confidence" => 88,
      "alternatives_considered" => ["Keep the original direction"],
      "reversibility_belief" => "reversible"
    }
  end

  def start_decision_store(name, dispatcher, opts \\ []) do
    dir = Aiur.TestSupport.tmp_root!("aiur-dashboard-decisions")
    previous = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, dir)

    on_exit(fn ->
      restore_application_env(:decision_state_dir, previous)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    defaults = [
      name: name,
      state_dir: dir,
      dispatcher: dispatcher,
      dispatch_delay_ms: 0,
      retry_delays_ms: [],
      reconcile_delay_ms: 5_000,
      filesystem_sync_fun: fn -> :ok end
    ]

    start_supervised!({DecisionStore, Keyword.merge(defaults, opts)})
  end

  def request_dashboard_decision(store, source_id, reversibility \\ "reversible", opts \\ []) do
    {decision_authority, opts} = Keyword.pop(opts, :decision_authority)
    # Blocking by default, but a fixture that only needs historic rows must be
    # able to opt out: the store refuses to dismiss a blocking Command it
    # cannot release.
    {blocking?, opts} = Keyword.pop(opts, :blocking, true)

    request =
      %{
        "source_id" => source_id,
        "question" => Aiur.DecisionStoreCase.question_with_identity("Should the dashboard ship this change?", source_id),
        "blocking" => blocking?,
        "urgency" => "critical",
        "reversibility" => reversibility,
        "options" => [
          %{
            "id" => "ship",
            "label" => "Ship it",
            "description" => "Proceed with the reviewed change"
          }
        ],
        "recommendation" => %{"option_id" => "ship", "reason" => "Checks are green"}
      }
      |> then(fn request ->
        if is_atom(decision_authority),
          do: Map.put(request, "authority", decision_authority),
          else: request
      end)

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               request,
               Keyword.merge(
                 [
                   ticket: %{
                     identifier: "AIUR-987",
                     title: "Operator Control Center",
                     url: "https://example.test/issues/987"
                   },
                   source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-#{source_id}"}
                 ],
                 opts
               ),
               store
             )

    decision
  end

  def add_newer_dashboard_decisions(store, decision, source_prefix) do
    for index <- 1..50 do
      request_dashboard_decision(
        store,
        "#{source_prefix}-#{index}",
        "reversible",
        now: DateTime.add(decision.created_at, index, :second)
      )
    end
  end

  def replace_dashboard_decision(store, decision, attrs) do
    assert {:ok, %{decision: replacement}} =
             DecisionStore.request(
               %{
                 "source_id" => decision.source_id,
                 "version" => decision.version + 1,
                 "question" => Keyword.fetch!(attrs, :question),
                 "blocking" => true,
                 "urgency" => "critical",
                 "reversibility" => Keyword.fetch!(attrs, :reversibility),
                 "options" => [
                   %{
                     "id" => "ship",
                     "label" => Keyword.fetch!(attrs, :option_label),
                     "description" => "The option ID is intentionally reused with a different meaning"
                   }
                 ],
                 "recommendation" => %{"option_id" => "ship", "reason" => "Current retained evidence"}
               },
               [ticket: decision.ticket, source: decision.source],
               store
             )

    replacement
  end

  def start_versioned_detail_store(name, overview, detail) do
    opts = [name: name, overview: overview, detail: detail, report: self()]
    start_supervised!({VersionedDetailStore, opts})
  end

  def start_stale_detail_store(name, overview, detail_status) do
    opts = [name: name, overview: overview, detail_status: detail_status, report: self()]
    start_supervised!({StaleDetailStore, opts})
  end

  def dashboard_decision(decision_id) do
    %Decision{
      decision_id: decision_id,
      source_id: decision_id,
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "Operator Control Center", url: "https://example.test/issues/987"},
      source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-stale"},
      kind: "architecture",
      authority: :human_required,
      urgency: :critical,
      blocking: true,
      reversibility: :reversible,
      question: "Which implementation should ship?",
      context: %{short_summary: "A newer version exists", long_context_markdown: nil},
      options: [],
      recommendation: nil,
      consequence_of_delay: "The agent remains paused.",
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      source_created_at: nil,
      content_hash: "stale-dashboard-hash"
    }
  end

  def await_dispatched_revision(store, decision_id) do
    assert eventually(
             fn -> match?({:ok, %{revision_result: :dispatched}}, DecisionStore.get(decision_id, store)) end,
             200
           ),
           "the store never recorded the revision dispatch: #{inspect(DecisionStore.get(decision_id, store))}"

    DecisionStore.get(decision_id, store)
  end

  def history_entry(id, actor_type, actor_label, question) do
    %{
      decision_id: id,
      ticket: %{identifier: "983", title: "OCC-6", url: "https://github.com/owner/repo/issues/983"},
      question: question,
      source_version: 1,
      changed_at: "2026-07-12T18:00:00Z",
      change: :requested,
      actor: %{type: actor_type, id: actor_label, label: actor_label},
      choice: nil,
      rationale: nil,
      dispatch_result: nil,
      acknowledgement_result: nil,
      revision_of: nil,
      superseded_by: nil,
      revised?: false
    }
  end

  def merged_event do
    %{
      "id" => "dashboard-merge",
      "type" => "PullRequestEvent",
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 42,
          "title" => "<img src=x onerror=alert(1)>",
          "body" => "Repository merge",
          "html_url" => "https://github.com/owner/repo/pull/42",
          "merged" => true,
          "merged_at" => "2026-07-12T18:00:00Z",
          "head" => %{"ref" => "release/2026-07", "sha" => "head-42"},
          "merged_by" => %{"login" => "merger"}
        }
      }
    }
  end
end

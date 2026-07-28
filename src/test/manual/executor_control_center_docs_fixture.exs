defmodule Aiur.Docs.ControlCenterFixture.Provider do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call(:snapshot, _from, %{snapshot: snapshot} = state), do: {:reply, snapshot, state}
  def handle_call(:snapshots, _from, state), do: {:reply, state.metrics, state}

  # Mirror Aiur.Orchestrator.GlobalPause's control API. Without these clauses the
  # provider FunctionClauseErrors on the first tap of the nav pause toggle, and
  # because `start_provider/2` links it to the script process, that crash takes
  # the whole fixture server down.
  def handle_call(:globally_paused?, _from, state) do
    {:reply, globally_paused?(state), state}
  end

  def handle_call({:set_global_pause, on?}, _from, state) when is_boolean(on?) do
    # The real switch holds every running agent that is not already individually
    # paused, so the synthetic fleet mirrors that: running rows gain a
    # `:global_pause` reason on pause and shed exactly that reason on resume.
    snapshot =
      state
      |> Map.fetch!(:snapshot)
      |> Map.put(:globally_paused, on?)
      |> Map.update(:running, [], fn running -> Enum.map(running, &apply_global_pause(&1, on?)) end)

    {:reply, {:ok, %{globally_paused: on?}}, %{state | snapshot: snapshot}}
  end

  def handle_call({:recent_decisions, limit}, _from, state) do
    {:reply, Enum.take(state.decisions, limit), state}
  end

  def handle_call({:recent_audit_history, limit}, _from, state) do
    {:reply, %{records: Enum.take(state.history, limit), contexts: %{}, revisions: %{}}, state}
  end

  # Per-decision latency lookup (Aiur.DecisionMetrics.snapshot/2).
  def handle_call({:snapshot, decision_id}, _from, %{metrics: metrics} = state) when is_binary(decision_id) do
    reply =
      case Map.fetch(metrics, decision_id) do
        {:ok, sample} -> {:ok, sample}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  # Mirror Aiur.DecisionStore's :retained_counts reply so the dashboard's
  # PayloadLoader can render the overview counts. Derived from the synthetic
  # decisions this provider holds.
  def handle_call(:retained_counts, _from, %{decisions: decisions} = state) do
    open = Enum.count(decisions, &(&1.decision_status == :open))
    blocking = Enum.count(decisions, &(&1.decision_status == :open and &1.blocking))
    counts = %{open: open, blocking: blocking, total: length(decisions)}
    {:reply, {:ok, %{counts: counts, health: :writable}}, state}
  end

  # Mirror Aiur.DecisionStore's {:retained_query, query} paged reply so the
  # Commands view can list decisions. The synthetic set is small, so return a
  # single bounded page without cursor pagination.
  def handle_call({:retained_query, query}, _from, %{decisions: decisions} = state) do
    limit = Map.get(query, :limit, 25)
    page = Enum.take(decisions, limit)
    open = Enum.count(decisions, &(&1.decision_status == :open))
    blocking = Enum.count(decisions, &(&1.decision_status == :open and &1.blocking))

    snapshot = %{
      decisions: page,
      next_key: nil,
      has_next?: false,
      total: length(decisions),
      partial?: false,
      partial_reason: nil,
      counts: %{open: open, blocking: blocking, total: length(decisions)},
      health: :writable
    }

    {:reply, {:ok, snapshot}, state}
  end

  # Mirror Aiur.DecisionStore's dismiss so the Commands view's Dismiss button
  # works against synthetic data instead of killing the provider.
  def handle_call({:dismiss, decision_id, _opts}, _from, %{decisions: decisions} = state) do
    case Enum.find(decisions, &(&1.decision_id == decision_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{decision_status: :dismissed} = decision ->
        {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

      %{decision_status: :open} = decision ->
        updated = %{decision | decision_status: :dismissed}
        decisions = Enum.map(decisions, &if(&1.decision_id == decision_id, do: updated, else: &1))
        {:reply, {:ok, %{status: :accepted, decision: updated}}, %{state | decisions: decisions}}

      %{decision_status: status} ->
        {:reply, {:error, {:conflict, status}}, state}
    end
  end

  # Every provider here is `start_link`ed from the run process, so ANY unmatched
  # call takes the whole fixture down — that is how a single dashboard button
  # killed the server twice. Fail the one call instead of the process; the
  # dashboard already degrades on an error reply. Keep adding real clauses
  # above as the control surface grows, but never let drift be fatal again.
  def handle_call(request, _from, state) do
    IO.warn("docs fixture has no clause for #{inspect(request)} — returning an error reply")
    {:reply, {:error, :unsupported_in_docs_fixture}, state}
  end

  defp globally_paused?(state) do
    state |> Map.get(:snapshot, %{}) |> Map.get(:globally_paused, false) == true
  end

  defp apply_global_pause(agent, true) do
    if Map.get(agent, :pause_reason) do
      agent
    else
      Map.merge(agent, %{pause_reason: :global_pause, waiting_reason: :run_paused, work_state: :paused})
    end
  end

  defp apply_global_pause(%{pause_reason: :global_pause} = agent, false) do
    Map.merge(agent, %{pause_reason: nil, waiting_reason: :active, work_state: :working})
  end

  defp apply_global_pause(agent, false), do: agent
end

defmodule Aiur.Docs.ControlCenterFixture do
  alias Aiur.{Decision, DecisionAnswer, RecentMerge}
  alias Aiur.Docs.ControlCenterFixture.Provider
  alias Aiur.ProviderMeters.Store, as: ProviderMeterStore
  alias AiurWeb.FinancialDataAccess.Generation

  @port String.to_integer(System.get_env("AIUR_DOCS_PORT", "4099"))

  def run do
    tmp = System.fetch_env!("AIUR_DOCS_TMP")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "telemetry.ndjson"), "{}\n")
    File.write!(Path.join(tmp, "config"), synthetic_workflow(tmp))
    Process.put(:fixture_now, DateTime.utc_now() |> DateTime.truncate(:second))

    Application.put_env(:aiur, :log_file, Path.join(tmp, "aiur.log"))
    Application.put_env(:aiur, :workflow_file_path, Path.join(tmp, "config"))

    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)
    # The Claude meter reads its quota over HTTP; without this every request
    # fails and the card reads N/A for a reason that has nothing to do with the
    # account.
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Aiur.PubSub}], strategy: :one_for_one)

    decisions = decisions()

    # Real provider meters, not synthetic ones. The projection reads Claude's
    # account usage endpoint directly, so it needs no agents and no daemon —
    # which makes this fixture the cheapest way to see actual quota on a
    # surface. Dashboard auth is configured because the meter cards sit behind
    # the financial-data capability, and that capability can only be granted by
    # a real session proof.
    System.put_env("AIUR_DASHBOARD_USERNAME", "aiur")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "aiur")

    # Without this the credential check cannot mint a configuration generation,
    # so it returns :error and every request 401s regardless of what is typed.
    {:ok, _} = Generation.start_link([])
    {:ok, _} = AiurWeb.FinancialData.start_link([])

    # Codex reaches the projection the long way round — its app-server session
    # ingests into the meter store, which broadcasts — so both of these must be
    # running or the Codex card stays N/A while the probe silently succeeds.
    # Claude needs neither: it broadcasts its own reading.
    {:ok, _} = Aiur.ProviderAccountGeneration.start_link([])
    {:ok, _} = ProviderMeterStore.start_link([])

    {:ok, _} = Aiur.ProviderMeterProjection.start_link([])
    {:ok, _} = Aiur.ProviderMeterRefresh.start_link(baseline_delay_ms: 500)

    start_provider(:docs_orchestrator, snapshot: fleet_snapshot())

    start_provider(:docs_decisions,
      decisions: decisions,
      history: history(),
      snapshot: %{}
    )

    start_provider(:docs_metrics,
      metrics: metrics(decisions),
      snapshot: %{}
    )

    start_provider(:docs_merges,
      snapshot: %{
        merges: recent_merges(),
        health: :writable,
        reconciliation: %{status: :complete, partial?: false, pages_fetched: 2}
      }
    )

    configure_endpoint()
    {:ok, _} = AiurWeb.Endpoint.start_link()

    IO.puts("Operator Control Center docs fixture ready at http://127.0.0.1:#{@port}")
    Process.sleep(:infinity)
  end

  defp start_provider(name, opts) do
    {:ok, _} = Provider.start_link(Keyword.put(opts, :name, name))
  end

  defp configure_endpoint do
    writable = System.get_env("AIUR_DOCS_WRITABLE", "false") == "true"

    config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: true,
        http: [ip: {127, 0, 0, 1}, port: @port],
        url: [host: "127.0.0.1", port: @port],
        secret_key_base: String.duplicate("d", 64),
        dashboard_writable: writable,
        # Auth on: the meter cards are gated behind the financial-data
        # capability, which is only granted to a session carrying a real proof.
        dashboard_auth_required: true,
        orchestrator: :docs_orchestrator,
        decision_store: :docs_decisions,
        decision_metrics: :docs_metrics,
        recent_merge_store: :docs_merges,
        control_center_cache: false,
        snapshot_timeout_ms: 1_000
      )

    Application.put_env(:aiur, AiurWeb.Endpoint, config)
  end

  defp fleet_snapshot do
    %{
      running: [
        running("EX-142", "Prepare example release", :active, 1, "Drafting the release checklist"),
        running("EX-143", "Review retry policy", :waiting_for_human, 1, "Waiting for a rollout decision")
      ],
      retrying: [
        %{
          issue_id: "example-144",
          identifier: "EX-144",
          state: "in-progress",
          title: "Validate example webhook",
          url: "https://example.test/tickets/EX-144",
          attempt: 2,
          due_in_ms: 42_000,
          error: "Synthetic upstream timeout",
          waiting_reason: :backing_off,
          open_decision_count: 0,
          ci_result: nil
        }
      ],
      idle: [
        %{
          issue_id: "example-145",
          identifier: "EX-145",
          state: "human-review",
          title: "Publish example changelog",
          url: "https://example.test/tickets/EX-145",
          tracker_paused: false,
          waiting_reason: :active,
          open_decision_count: 0,
          ci_result: %{decision: :pass, pr_number: 145, head_sha: "example145"}
        }
      ],
      agent_totals: %{input_tokens: 12_400, output_tokens: 3_180, total_tokens: 15_580, seconds_running: 1_860},
      rate_limits: %{primary: %{remaining_percent: 72}}
    }
  end

  defp running(identifier, title, waiting_reason, open_count, message) do
    %{
      issue_id: "example-#{identifier}",
      identifier: identifier,
      state: "in-progress",
      title: title,
      url: "https://example.test/tickets/#{identifier}",
      session_id: "example-session-#{identifier}",
      turn_count: 3,
      runtime_seconds: 840,
      work_state: :working,
      last_codex_event: "agent_message",
      last_codex_message: message,
      last_codex_timestamp: DateTime.add(now(), -35, :second),
      started_at: DateTime.add(now(), -840, :second),
      stale_for_seconds: 35,
      waiting_reason: waiting_reason,
      open_decision_count: open_count,
      ci_result: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      agent_input_tokens: 4_200,
      agent_output_tokens: 980,
      agent_total_tokens: 5_180
    }
  end

  defp decisions do
    [
      decision("dec-example-blocking", "EX-143", "Choose the rollout window", :critical, true),
      decision("dec-example-recorded", "EX-142", "Which release note should lead?", :normal, false),
      answered("dec-example-pending", "EX-146", "Approve the staged retry policy?", :queued, :decided),
      answered("dec-example-delivered", "EX-147", "Use the synthetic canary cohort?", :delivered, :decided),
      answered("dec-example-acknowledged", "EX-148", "Continue after the example audit?", :consumed, :acknowledged),
      answered("dec-example-resolved", "EX-149", "Close the sample migration?", :consumed, :resolved),
      answered("dec-example-failed", "EX-150", "Retry the example notification?", :failed, :decided)
    ]
  end

  defp decision(id, ticket, question, urgency, blocking) do
    %Decision{
      decision_id: id,
      version: 1,
      ticket: %{identifier: ticket, title: "Synthetic ticket #{ticket}", url: "https://example.test/tickets/#{ticket}"},
      source: %{agent_id: "example-agent-#{ticket}"},
      authority: :human_required,
      urgency: urgency,
      blocking: blocking,
      reversibility: :reversible,
      question: question,
      context: %{
        short_summary: "Example-only context for the documentation fixture.",
        long_context_markdown: "This decision uses synthetic agents, tickets, and outcomes."
      },
      options: [
        %{id: "morning", label: "Morning window", description: "Use the example morning window.", benefits: ["More coverage"], drawbacks: ["Slower start"], risk: :low},
        %{id: "evening", label: "Evening window", description: "Use the example evening window.", benefits: ["More preparation"], drawbacks: ["Smaller crew"], risk: :medium}
      ],
      artifacts: [%{kind: :url, value: "https://example.test/evidence/#{id}"}],
      recommendation: %{option_id: "morning", reason: "Lowest-risk synthetic option."},
      consequence_of_delay: "The example agent remains paused.",
      created_at: DateTime.add(now(), -900, :second),
      content_hash: "example-hash-#{id}"
    }
  end

  defp answered(id, ticket, question, delivery_status, decision_status) do
    base = decision(id, ticket, question, :normal, false)

    {:ok, answer} =
      DecisionAnswer.normalize(
        %{idempotency_key: "example-#{id}", expected_version: 1, option_id: "morning", rationale: "Synthetic rationale for the docs."},
        decision_id: id,
        decision_version: 1,
        options: base.options,
        actor: %{kind: :operator, id: "example-operator"},
        now: DateTime.add(now(), -600, :second)
      )

    attempts =
      if delivery_status == :failed do
        [%{action_id: answer.action_id, status: :failed, failure_reason_class: :target_unavailable}]
      else
        []
      end

    %{
      base
      | answer: answer,
        active_action_id: answer.action_id,
        decision_status: decision_status,
        delivery_status: delivery_status,
        dispatch_attempts: attempts,
        acknowledgement: acknowledgement(decision_status),
        resolution: resolution(decision_status)
    }
  end

  defp acknowledgement(status) when status in [:acknowledged, :resolved],
    do: %{actor: %{kind: :agent, id: "example-agent"}, acknowledged_at: DateTime.add(now(), -300, :second)}

  defp acknowledgement(_status), do: nil

  defp resolution(:resolved),
    do: %{actor: %{kind: :agent, id: "example-agent"}, resolved_at: DateTime.add(now(), -120, :second)}

  defp resolution(_status), do: nil

  defp history do
    [
      %{
        decision_id: "dec-example-resolved",
        ticket: %{identifier: "EX-149"},
        question: "Close the sample migration?",
        changed_at: DateTime.add(now(), -120, :second),
        event_kind: :resolved,
        actor: %{type: :ticket_agent, id: "example-agent", label: "Ticket agent"},
        choice: "Morning window",
        rationale: "All synthetic checks passed.",
        dispatch_result: :delivered,
        acknowledgement_result: :acknowledged
      },
      %{
        decision_id: "dec-example-pending",
        ticket: %{identifier: "EX-146"},
        question: "Approve the staged retry policy?",
        changed_at: DateTime.add(now(), -520, :second),
        event_kind: :answered,
        actor: %{type: :human_operator, id: "example-operator", label: "Executor"},
        choice: "Morning window",
        rationale: "Synthetic rationale for the docs.",
        dispatch_result: :queued
      }
    ]
  end

  defp metrics(decisions) do
    Map.new(decisions, fn decision ->
      {decision.decision_id,
       %{
         requested_at: DateTime.add(now(), -900, :second),
         answered_at: if(decision.answer, do: DateTime.add(now(), -600, :second)),
         delivered_at: if(decision.delivery_status in [:delivered, :consumed], do: DateTime.add(now(), -450, :second)),
         acknowledged_at: if(decision.decision_status in [:acknowledged, :resolved], do: DateTime.add(now(), -300, :second)),
         resolved_at: if(decision.decision_status == :resolved, do: DateTime.add(now(), -120, :second))
       }}
    end)
  end

  defp recent_merges do
    [
      recent_merge(318, "Publish synthetic retry guide", "EX-142", DateTime.add(now(), -1_800, :second)),
      recent_merge(317, "Add example release checks", "EX-145", DateTime.add(now(), -4_200, :second))
    ]
  end

  defp recent_merge(number, title, ticket, merged_at) do
    %RecentMerge{
      id: "example/repository##{number}",
      repository: "example/repository",
      number: number,
      url: "https://example.test/pulls/#{number}",
      title: title,
      summary: "Synthetic merged outcome used only for documentation.",
      ticket_id: ticket,
      merged_at: merged_at,
      observation_source: :github_events,
      backfilled?: false,
      live_observed?: true,
      observed_run_id: "example-run",
      first_observed_at: merged_at,
      last_observed_at: merged_at,
      content_hash: "example-merge-hash-#{number}"
    }
  end

  defp synthetic_workflow(tmp) do
    """
    tracker:
      kind: memory
      active_states: [todo, in-progress]
      terminal_states: [done]
    agent:
      kind: codex
      max_concurrent_agents: 1
      max_turns: 1
    polling:
      interval_seconds: 30
    workspace:
      root: #{Path.join(tmp, "workspaces")}
    observability:
      dashboard_enabled: true
      dashboard_writable: false
    server:
      host: 127.0.0.1
      port: #{@port}
    """
  end

  defp now, do: Process.get(:fixture_now)
end

Aiur.Docs.ControlCenterFixture.run()

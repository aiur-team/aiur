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
    {:reply, {:ok, %{counts: counts(decisions), health: :writable}}, state}
  end

  # Mirror Aiur.DecisionStore's {:retained_query, query} paged reply, including
  # the lifecycle filter and cursor paging the Commands view relies on. A
  # fixture that returns every decision for every query cannot show whether
  # pagination works.
  def handle_call({:retained_query, query}, _from, %{decisions: decisions} = state) do
    limit = Map.get(query, :limit, 25)

    matching =
      decisions
      |> Enum.filter(&lifecycle_match?(&1, Map.get(query, :lifecycle)))
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    after_cursor =
      case Map.get(query, :cursor) do
        %{decision_id: decision_id} -> Enum.drop_while(matching, &(&1.decision_id != decision_id)) |> Enum.drop(1)
        _no_cursor -> matching
      end

    page = Enum.take(after_cursor, limit)
    has_next? = length(after_cursor) > limit

    next_key =
      if has_next? do
        last = List.last(page)
        {-DateTime.to_unix(last.created_at, :microsecond), last.decision_id}
      end

    snapshot = %{
      decisions: page,
      next_key: next_key,
      has_next?: has_next?,
      total: length(matching),
      partial?: false,
      partial_reason: nil,
      counts: counts(decisions),
      health: :writable
    }

    {:reply, {:ok, snapshot}, state}
  end

  # Mirror Aiur.DecisionStore's answer and defer so the two actions that move a
  # Command out of the inbox can be exercised against synthetic data. Without
  # them the fixture rejects every write, and the card correctly refuses to
  # move — which looks like a dismissal bug rather than a missing fixture.
  def handle_call({:answer, decision_id, payload, _opts}, _from, %{decisions: decisions} = state) do
    with %{decision_status: status} = decision when status in [:open, :deferred] <-
           Enum.find(decisions, &(&1.decision_id == decision_id)),
         {:ok, answer} <-
           Aiur.DecisionAnswer.normalize(payload,
             decision_id: decision_id,
             decision_version: decision.version,
             options: decision.options,
             actor: %{kind: :operator, id: "example-operator"},
             now: DateTime.utc_now()
           ) do
      updated = %{decision | answer: answer, active_action_id: answer.action_id, decision_status: :decided}
      {:reply, {:ok, %{status: :accepted, decision: updated}}, replace(state, updated)}
    else
      nil -> {:reply, {:error, :not_found}, state}
      %{decision_status: status} -> {:reply, {:error, {:conflict, status}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:defer, decision_id, _opts}, _from, %{decisions: decisions} = state) do
    case Enum.find(decisions, &(&1.decision_id == decision_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{decision_status: :deferred} = decision ->
        {:reply, {:ok, %{status: :duplicate, decision: decision}}, state}

      %{decision_status: :open} = decision ->
        updated = %{decision | decision_status: :deferred}
        {:reply, {:ok, %{status: :accepted, decision: updated}}, replace(state, updated)}

      %{decision_status: status} ->
        {:reply, {:error, {:conflict, status}}, state}
    end
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

  defp replace(%{decisions: decisions} = state, updated) do
    %{state | decisions: Enum.map(decisions, &if(&1.decision_id == updated.decision_id, do: updated, else: &1))}
  end

  @open_statuses [:open, :deferred]
  @historic_statuses [:expired, :dismissed, :decided, :acknowledged, :resolved]
  @history_statuses [:deferred | @historic_statuses]

  defp counts(decisions) do
    open = Enum.count(decisions, &(&1.decision_status in @open_statuses))
    blocking = Enum.count(decisions, &(&1.decision_status in @open_statuses and &1.blocking))
    deferred = Enum.count(decisions, &(&1.decision_status == :deferred))
    deferred_blocking = Enum.count(decisions, &(&1.decision_status == :deferred and &1.blocking))

    %{
      open: open,
      blocking: blocking,
      deferred: deferred,
      awaiting: open - deferred,
      awaiting_blocking: blocking - deferred_blocking,
      total: length(decisions)
    }
  end

  defp lifecycle_match?(_decision, nil), do: true
  defp lifecycle_match?(decision, :open), do: decision.decision_status in @open_statuses
  defp lifecycle_match?(decision, :awaiting), do: decision.decision_status == :open
  defp lifecycle_match?(decision, :historic), do: decision.decision_status in @historic_statuses
  defp lifecycle_match?(decision, :history), do: decision.decision_status in @history_statuses
  defp lifecycle_match?(decision, lifecycle), do: decision.decision_status == lifecycle

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

defmodule Aiur.Docs.ControlCenterFixture.MeterSource do
  @moduledoc false

  # DOCUMENTATION SAFETY BOUNDARY.
  #
  # The production `AiurWeb.OperatorControlCenter.ProviderMeterSource` reads
  # `Aiur.ProviderMeterProjection`, which is fed by `Aiur.ProviderMeterRefresh`
  # probing the operator's real Claude and Codex accounts over HTTP with
  # whatever ambient credentials the shell carries. That is live account data
  # and it must never reach a checked-in screenshot, so this fixture never
  # starts those probes and installs this stand-in through the endpoint's
  # `:provider_meter_source` seam instead. It performs no I/O and returns fixed
  # synthetic readings for both providers.

  alias Aiur.ProviderMeterSnapshot

  # Relative to the capture, not a fixed calendar date: a hard-coded reset in the
  # past renders as "reset time passed" on every card.
  defp observed_at, do: DateTime.add(DateTime.utc_now(), -720, :second)
  defp session_reset, do: DateTime.add(DateTime.utc_now(), 4_320, :second)
  defp weekly_reset, do: DateTime.add(DateTime.utc_now(), 331_200, :second)

  def subscribe(_context), do: :ok
  def load(_context, _opts \\ []), do: snapshots()
  def reload(_context, _message, _opts \\ []), do: snapshots()

  def snapshots do
    %{
      claude: snapshot(:claude, :cli, "example-account-claude", :max, 34, 58),
      codex: snapshot(:codex, :app_server, "example-account-codex", :pro, 61, 47)
    }
  end

  # The Stream Deck projection takes its meters as a plain map, not a struct.
  def streamdeck_meters do
    %{
      "claude" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 34, "remaining" => "3h 48m", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 58, "remaining" => "4d", "freshness" => "fresh"}
        }
      },
      "codex" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 61, "remaining" => "1h 12m", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 47, "remaining" => "4d", "freshness" => "fresh"}
        }
      }
    }
  end

  defp snapshot(provider, backend, generation, tier, session_used, weekly_used) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: backend,
      provider_account_generation: generation,
      projection_generation: 1,
      auth_mode: :subscription,
      plan: %{tier: tier, source: :provider, observed_at: observed_at(), freshness: :fresh},
      update_kind: :snapshot,
      observed_at: observed_at(),
      age_seconds: 12,
      ingested_at: observed_at(),
      source: :example_fixture,
      source_version: 1,
      full_snapshot_observed_at: observed_at(),
      freshness: :fresh,
      health: %{
        state: :healthy,
        failure: nil,
        last_observed_at: observed_at(),
        last_source_version: 1,
        last_attempt_at: observed_at(),
        consecutive_failures: 0
      },
      windows: %{
        "session" => window("Session", session_used, session_reset(), provider),
        "weekly" => window("Weekly", weekly_used, weekly_reset(), provider)
      }
    }
  end

  defp window(name, used_percent, resets_at, provider) do
    %{
      kind: :rate_limit,
      name: name,
      standing: :allowed,
      used_percent: used_percent,
      remaining_percent: 100 - used_percent,
      coverage: :supported,
      freshness: :fresh,
      resets_at: resets_at,
      source: provider
    }
  end
end

defmodule Aiur.Docs.ControlCenterFixture do
  alias Aiur.BuildOrder.ProviderHealth
  alias Aiur.{Decision, DecisionAnswer, RecentMerge}
  alias Aiur.Docs.ControlCenterFixture.MeterSource
  alias Aiur.Docs.ControlCenterFixture.Provider
  alias Aiur.GitHub.Quota
  alias Aiur.Orchestrator.SnapshotStore
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

    {:ok, _} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Aiur.PubSub}, {Task.Supervisor, name: Aiur.TaskSupervisor}],
        strategy: :one_for_one
      )

    decisions = decisions()

    # Documentation captures use SYNTHETIC provider meters only. The real
    # `Aiur.ProviderMeterRefresh` / `Aiur.ProviderMeterProjection` pair probes
    # the operator's own Claude and Codex accounts over HTTP with ambient
    # credentials, so it is deliberately never started here — no `:req`, no
    # meter store, no account generation server. The endpoint's
    # `:provider_meter_source` seam points at
    # `Aiur.Docs.ControlCenterFixture.MeterSource` instead, which is pure data.
    #
    # Dashboard auth stays configured because the meter cards sit behind the
    # financial-data capability and that capability is only granted to a session
    # carrying a real proof. The credentials are the fixed example pair the
    # capture script sends; they guard nothing but a loopback fixture.
    System.put_env("AIUR_DASHBOARD_USERNAME", "example")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "example")

    # Without this the credential check cannot mint a configuration generation,
    # so it returns :error and every request 401s regardless of what is typed.
    {:ok, _} = Generation.start_link([])
    {:ok, _} = AiurWeb.FinancialData.start_link([])

    configure_build_order_pack(tmp)
    start_github_quota(tmp)

    start_provider(:docs_orchestrator, snapshot: fleet_snapshot())
    publish_fleet_snapshot()

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

  # The Units page reads its fleet from `SnapshotStore`, not from the
  # orchestrator process, so a provider that only answers `:snapshot` renders an
  # empty page. Publish the synthetic fleet into the read model and keep
  # republishing it: a retained snapshot ages out after two minutes and would
  # otherwise be captured behind a "last known good" staleness banner.
  defp publish_fleet_snapshot do
    snapshot = fleet_snapshot()
    _generation = SnapshotStore.begin_generation(:docs_orchestrator)
    :ok = SnapshotStore.publish(:docs_orchestrator, snapshot)

    spawn_link(fn ->
      Stream.repeatedly(fn ->
        Process.sleep(5_000)
        SnapshotStore.publish(:docs_orchestrator, snapshot)
      end)
      |> Stream.run()
    end)

    :ok
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
        snapshot_timeout_ms: 1_000,
        # The Units catalog joins current-run membership, ticket activity, and
        # the open-ticket listing. All three read GitHub in production, so all
        # three are replaced by synthetic readers here.
        units_membership_fun: &__MODULE__.units_membership/0,
        units_activity_fun: &__MODULE__.units_activity/0,
        # Never the real projection — see MeterSource's documentation-safety note.
        provider_meter_source: MeterSource,
        streamdeck_provider_meters_fun: &MeterSource.streamdeck_meters/0,
        # The Stream Deck emulator projects its own fleet snapshot rather than
        # the Units orchestrator bucket list, so it gets a dedicated synthetic
        # fleet wide enough to fill the eight-key grid and its pager.
        streamdeck_fixture_fleet: true,
        streamdeck_snapshot_fun: &__MODULE__.streamdeck_snapshot/0,
        agent_chat_pause_fun: &__MODULE__.streamdeck_noop/1,
        agent_chat_resume_fun: &__MODULE__.streamdeck_noop/1
      )
      |> Keyword.delete(:streamdeck_logs_fun)

    Application.put_env(:aiur, AiurWeb.Endpoint, config)
  end

  # --- GitHub quota ----------------------------------------------------------

  # The run summary strip reads `Aiur.GitHub.Quota`. Left unstarted it reads
  # "Awaiting GitHub response"; started with its default options it would poll
  # GitHub with the operator's credential. It is started here with refreshing
  # disabled, alerts silenced, and its on-disk state confined to the fixture's
  # temporary directory, then fed one synthetic budget observation.
  defp start_github_quota(tmp) do
    {:ok, _} =
      Quota.start_link(
        refresh?: false,
        emit_fun: fn _kind, _payload -> :ok end,
        shell_log_path: Path.join(tmp, "github-shell-quota.ndjson"),
        hold_dir: Path.join(tmp, "github-holds")
      )

    reset = DateTime.utc_now() |> DateTime.add(1_920, :second) |> DateTime.to_unix()

    Quota.observe(%{}, {
      :ok,
      %{
        body: %{
          "resources" => %{
            "core" => %{"limit" => 5_000, "remaining" => 4_180, "reset" => reset},
            "graphql" => %{"limit" => 5_000, "remaining" => 3_640, "reset" => reset}
          }
        }
      }
    })

    :ok
  end

  # --- Units catalog ---------------------------------------------------------

  # Every synthetic unit, in the display order the Units table shows them, with
  # the lifecycle and progress each row should present.
  @units [
    {"EX-142", "Prepare example release", :active, 68},
    {"EX-143", "Review retry policy", :active, 45},
    {"EX-146", "Add example rate limiting", :active, 52},
    {"EX-147", "Render the example usage view", :active, 21},
    {"EX-148", "Seed the example dataset", :waiting, 12},
    {"EX-144", "Validate example webhook", :retrying, 33},
    {"EX-151", "Add example soak coverage", :retrying, 8},
    {"EX-145", "Publish example changelog", :paused, 90},
    {"EX-149", "Export example rollups", :queued, 0},
    {"EX-150", "Cache example catalogue reads", :queued, 0},
    {"EX-152", "Localise the example shell", :queued, 0},
    {"EX-153", "Write the example runbook", :queued, 0}
  ]

  @doc false
  def unit_identity(identifier) do
    struct!(Aiur.TrackerIdentity,
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "example-org",
      repository: "example-app",
      provider_id: "EXAMPLE_NODE_#{identifier}",
      database_id: unit_number(identifier),
      # A joinable GitHub identity's display identifier must parse as a positive
      # integer, so the EX- prefix is a presentation concern only.
      identifier: to_string(unit_number(identifier)),
      reason: nil
    )
  end

  defp unit_number("EX-" <> digits), do: String.to_integer(digits)

  @doc false
  def units_membership do
    observed_at = DateTime.utc_now()

    %{
      run_id: "example-run",
      generation: 1,
      health: :healthy,
      health_message: nil,
      freshness: %{status: :fresh, observed_at: observed_at},
      truncated?: false,
      members:
        Enum.map(@units, fn {identifier, _title, lifecycle, _progress} ->
          %{
            identity: unit_identity(identifier),
            lifecycle: lifecycle,
            terminal?: lifecycle in [:completed, :cancelled],
            first_observed_at: DateTime.add(observed_at, -3_600, :second),
            last_observed_at: observed_at
          }
        end)
    }
  end

  @doc false
  def units_activity do
    %{
      generation: 1,
      health: :healthy,
      freshness: %{status: :fresh},
      entries:
        Enum.map(@units, fn {identifier, _title, _lifecycle, progress} ->
          %{
            identity: unit_identity(identifier),
            progress: %{status: :known, percent: progress, source: :checkin, freshness: :fresh},
            latest_evidence: %{status: :known, source: %{kind: :branch, name: "example/#{String.downcase(identifier)}"}}
          }
        end)
    }
  end

  @doc false
  # --- Build Order -----------------------------------------------------------

  # The spatial Build Order page reads whatever module sits in
  # `:build_order_data_source`. `PlanningSource` renders a graph straight from a
  # local planning pack, so the fixture writes a synthetic pack into its own
  # temporary directory and points the source at it. Nothing here touches
  # GitHub: the two collaborators that would (`CurrentRunMembership` and the
  # pack-status poller) are replaced by their documented stub seams.
  defp configure_build_order_pack(tmp) do
    directory = Path.join(tmp, "build_orders")
    File.mkdir_p!(directory)
    pack = Path.join(directory, "example-pack.json")

    File.write!(pack, Jason.encode!(build_order_pack(), pretty: true))
    File.write!(Path.join(directory, "status.json"), Jason.encode!(build_order_status(), pretty: true))

    Application.put_env(:aiur, :build_order_data_source, AiurWeb.BuildOrder.PlanningSource)
    Application.put_env(:aiur, :build_order_planning_pack, pack)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{health: :healthy, freshness: %{status: :fresh}, generation: 1, members: []}
    end)

    # `now/0` reads the run process's dictionary, so the observation time is
    # captured here rather than inside the closure the LiveView process calls.
    observed_at = now()

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(1, :healthy, true, observed_at: observed_at)
    end)
  end

  @build_order_root 4_200
  @build_order_lanes ~w(platform core api web data quality)

  # A pack shaped like a real plan: six lanes across seven phases, every ticket
  # depending on work from an earlier phase, so the graph draws phase barriers
  # and lane columns instead of one lonely node.
  defp build_order_pack do
    %{
      schema_version: 1,
      build_order_id: "example-org/example-app:launch",
      title: "Example App launch",
      subtitle: "Synthetic planning pack used only for documentation screenshots",
      repository: "example-org/example-app",
      root_number: @build_order_root,
      root_node_id: "EXAMPLE_BUILD_ORDER_ROOT",
      plan_version: 1,
      icon: "cube",
      workstreams: Enum.map(@build_order_lanes, &%{id: &1, title: String.capitalize(&1)}),
      tickets: build_order_tickets()
    }
  end

  defp build_order_tickets do
    Enum.map(build_order_plan(), fn {id, title, lane, phase, complexity, depends_on} ->
      %{
        id: id,
        title: title,
        lane: lane,
        phase: phase,
        complexity: complexity,
        depends_on: depends_on,
        ticket: build_order_number(id),
        doc: "tickets/#{id}.md"
      }
    end)
  end

  defp build_order_number("EX-" <> digits), do: String.to_integer(digits)

  # Phases 1-3 are finished, 4 is in flight, 5-7 are still planned — the mix the
  # Build Order graph is designed to show.
  @build_order_completed ~w(EX-401 EX-402 EX-403 EX-404 EX-405 EX-406 EX-407 EX-408 EX-409 EX-410 EX-411)
  @build_order_cancelled ~w(EX-412)

  defp build_order_status do
    members =
      Map.new(build_order_plan(), fn {id, _title, _lane, _phase, _complexity, _depends_on} ->
        state =
          cond do
            id in @build_order_completed -> "completed"
            id in @build_order_cancelled -> "cancelled"
            true -> "open"
          end

        {to_string(build_order_number(id)), %{"lifecycle" => state}}
      end)

    %{"state" => "in_progress", "members" => members}
  end

  defp build_order_plan do
    [
      {"EX-401", "Scaffold the example monorepo and toolchain", "platform", 1, 3, []},
      {"EX-402", "Add the continuous integration gate", "platform", 2, 2, ["EX-401"]},
      {"EX-403", "Define shared domain primitives", "core", 2, 2, ["EX-401"]},
      {"EX-404", "Publish the example design tokens", "web", 2, 2, ["EX-401"]},
      {"EX-405", "Model the account and workspace schema", "data", 3, 3, ["EX-403"]},
      {"EX-406", "Add the migration runner", "data", 3, 2, ["EX-403"]},
      {"EX-407", "Expose the read-only catalogue endpoint", "api", 3, 3, ["EX-403"]},
      {"EX-408", "Build the application shell and routing", "web", 3, 3, ["EX-404"]},
      {"EX-409", "Add the request contract test suite", "quality", 3, 2, ["EX-402"]},
      {"EX-410", "Wire structured logging and request ids", "platform", 3, 2, ["EX-402"]},
      {"EX-411", "Seed the example dataset", "data", 4, 2, ["EX-405", "EX-406"]},
      {"EX-412", "Retire the placeholder catalogue stub", "api", 4, 1, ["EX-407"]},
      {"EX-413", "Add session issue and refresh", "api", 4, 3, ["EX-405"]},
      {"EX-414", "Render the catalogue list view", "web", 4, 3, ["EX-407", "EX-408"]},
      {"EX-415", "Add the golden-path browser suite", "quality", 4, 3, ["EX-408"]},
      {"EX-416", "Cache catalogue reads at the edge", "platform", 4, 2, ["EX-407"]},
      {"EX-417", "Add the write path for saved views", "api", 5, 3, ["EX-413"]},
      {"EX-418", "Render the saved-view editor", "web", 5, 4, ["EX-414"]},
      {"EX-419", "Project daily usage rollups", "data", 5, 3, ["EX-411"]},
      {"EX-420", "Add rate limiting to the public API", "platform", 5, 2, ["EX-416"]},
      {"EX-421", "Add accessibility checks to the suite", "quality", 5, 2, ["EX-415"]},
      {"EX-422", "Add the usage dashboard", "web", 6, 4, ["EX-418", "EX-419"]},
      {"EX-423", "Export usage rollups as CSV", "api", 6, 2, ["EX-419"]},
      {"EX-424", "Add background job retries", "core", 6, 3, ["EX-411"]},
      {"EX-425", "Add load and soak coverage", "quality", 6, 3, ["EX-420"]},
      {"EX-426", "Add per-workspace usage alerts", "core", 6, 3, ["EX-419"]},
      {"EX-427", "Harden the deployment pipeline", "platform", 7, 3, ["EX-420", "EX-425"]},
      {"EX-428", "Write the launch runbook", "quality", 7, 2, ["EX-427"]},
      {"EX-429", "Localise the application shell", "web", 7, 3, ["EX-422"]},
      {"EX-430", "Publish the public API reference", "api", 7, 2, ["EX-423"]},
      {"EX-431", "Archive the example migration scripts", "data", 7, 1, ["EX-424"]},
      {"EX-432", "Add the release health check", "core", 7, 2, ["EX-427"]}
    ]
  end

  # --- Stream Deck -----------------------------------------------------------

  @doc false
  # The emulator's grid comes from this snapshot, in the same bucket shape the
  # orchestrator publishes. Every bucket is populated so each key face state —
  # alert, stuck, running, paused, queued — is visible in one capture.
  def streamdeck_snapshot do
    %{
      running: [
        streamdeck_agent("EX-142", "Prepare example release", "codex", progress_percent: 62),
        streamdeck_agent("EX-146", "Add example rate limiting", "claude", progress_percent: 41),
        streamdeck_agent("EX-147", "Render the example usage view", "codex", progress_percent: 18)
      ],
      retrying: [streamdeck_agent("EX-144", "Validate example webhook", "codex", work_state: :error, progress_percent: 100)],
      idle: [
        streamdeck_agent("EX-143", "Review retry policy", "claude", open_decision_count: 1),
        streamdeck_agent("EX-145", "Publish example changelog", "codex", work_state: :paused),
        streamdeck_agent("EX-148", "Seed the example dataset", "codex", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-149", "Export example rollups", "claude", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-150", "Cache example catalogue reads", "codex", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-151", "Add example soak coverage", "codex", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-152", "Localise the example shell", "claude", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-153", "Write the example runbook", "codex", waiting_reason: :waiting_for_dependency)
      ]
    }
  end

  @doc false
  # The capture never presses a key; this only keeps the control facade total.
  def streamdeck_noop(identifier), do: {:ok, to_string(identifier)}

  defp streamdeck_agent(identifier, title, backend, attrs) do
    Map.merge(
      %{
        identifier: identifier,
        title: title,
        backend: backend,
        work_state: :working,
        open_decision_count: 0,
        waiting_reason: :active,
        tracker_paused: false,
        progress_percent: 50,
        priority: nil
      },
      Map.new(attrs)
    )
  end

  defp fleet_snapshot do
    %{
      running: [
        running("EX-142", "Prepare example release", :active, 1, "Drafting the release checklist"),
        running("EX-143", "Review retry policy", :waiting_for_human, 1, "Waiting for a rollout decision"),
        running("EX-146", "Add example rate limiting", :active, 0, "Running the contract suite"),
        running("EX-147", "Render the example usage view", :active, 0, "Wiring the usage chart"),
        running("EX-148", "Seed the example dataset", :waiting_for_dependency, 0, "Waiting on the migration runner")
      ],
      retrying: [
        retrying("EX-144", "Validate example webhook", 2, 42_000, "Synthetic upstream timeout"),
        retrying("EX-151", "Add example soak coverage", 1, 118_000, "Synthetic sandbox restart")
      ],
      idle: [
        idle("EX-145", "Publish example changelog", "human-review", %{decision: :pass, pr_number: 145, head_sha: "example145"}),
        idle("EX-149", "Export example rollups", "human-review", %{decision: :fail, pr_number: 149, head_sha: "example149"}),
        idle("EX-150", "Cache example catalogue reads", "todo", nil),
        idle("EX-152", "Localise the example shell", "todo", nil),
        idle("EX-153", "Write the example runbook", "todo", nil)
      ],
      agent_totals: %{input_tokens: 128_400, output_tokens: 31_180, total_tokens: 159_580, seconds_running: 7_860},
      rate_limits: %{primary: %{remaining_percent: 72}}
    }
  end

  defp retrying(identifier, title, attempt, due_in_ms, error) do
    %{
      issue_id: "example-#{identifier}",
      identifier: identifier,
      tracker_identity: unit_identity(identifier),
      state: "in-progress",
      title: title,
      url: "https://example.test/tickets/#{identifier}",
      attempt: attempt,
      due_in_ms: due_in_ms,
      error: error,
      waiting_reason: :backing_off,
      open_decision_count: 0,
      ci_result: nil
    }
  end

  defp idle(identifier, title, state, ci_result) do
    %{
      issue_id: "example-#{identifier}",
      identifier: identifier,
      tracker_identity: unit_identity(identifier),
      state: state,
      title: title,
      url: "https://example.test/tickets/#{identifier}",
      tracker_paused: false,
      waiting_reason: :active,
      open_decision_count: 0,
      ci_result: ci_result
    }
  end

  defp running(identifier, title, waiting_reason, open_count, message) do
    %{
      issue_id: "example-#{identifier}",
      identifier: identifier,
      tracker_identity: unit_identity(identifier),
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
    ] ++ resolved_backlog()
  end

  # A run's Commands surface is mostly history. The fixture carries enough of it
  # to show what the operator actually faces, and to make a page that renders
  # every past Command obvious.
  defp resolved_backlog do
    Enum.map(1..24, fn index ->
      id = "dec-example-past-#{index}"
      ticket = "EX-#{200 + index}"

      {status, delivery} =
        case rem(index, 4) do
          0 -> {:resolved, :consumed}
          1 -> {:decided, :delivered}
          2 -> {:acknowledged, :consumed}
          3 -> {:deferred, :queued}
        end

      base = answered(id, ticket, "Synthetic past Command #{index}?", delivery, status)
      %{base | created_at: DateTime.add(now(), -1_800 - index * 600, :second)}
    end)
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

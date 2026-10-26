defmodule Aiur.Experiments.Packs.DeliverySpeed.TelemetrySource do
  @moduledoc "The pack's only reader of live telemetry, retained boots and usage accounting."
  alias Aiur.Claude.Telemetry.UsageAdapter.Relationship
  alias Aiur.Experiments.Packs.DeliverySpeed.Tokens
  alias Aiur.Experiments.Paths
  alias Aiur.Experiments.Sources.Common
  alias Aiur.Experiments.{TelemetryHistory, TelemetryReader}
  alias Aiur.LandingWatch.Journal
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Dataset
  alias Aiur.RunTelemetry.Dataset.Source
  alias Aiur.Usage.Headless.Catalog
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @events ~w(dispatch pr_opened pr_merged review_pause rework_start comment_received)
  @attributes %{
    "run_context" => ~w(aiur_vsn config_hash capture_tags),
    "lifecycle" =>
      ~w(event boundary ticket attempt_id complexity backend model effort feature epic work_kind tags blockers start_mode source source_timestamp author_trusted review_thread_id event_key source_id operation_id segment_continuation)
  }

  @spec load(map(), map()) :: {:ok, map()} | {:error, term()}
  def load(window, ctx) do
    if Map.get_lazy(ctx, :telemetry_enabled, &Aiur.Config.telemetry_enabled?/0) do
      load_enabled(window, ctx)
    else
      {:error, :telemetry_disabled}
    end
  end

  defp load_enabled(window, ctx) do
    boot = Map.get_lazy(ctx, :boot_id, &RunTelemetry.boot_id/0)
    {prior, unreadable?} = prior_projection(boot, window, ctx)
    sources = Map.get_lazy(ctx, :telemetry_path, &RunTelemetry.telemetry_file/0) |> List.wrap() |> Source.discover_files() |> Enum.map(&%{path: &1, format: :ndjson})

    live =
      TelemetryReader.read(window, sources,
        history: true,
        projection: :fleet,
        keep_kinds: ~w(lifecycle run_context restart resource),
        max_records: 100_000,
        lifecycle_events: @events,
        attribute_keys: @attributes
      )

    with {:ok, live} <- live do
      cond do
        live.state == :truncated -> {:error, :truncated}
        prior.records == [] and live.records == [] -> {:error, :telemetry_missing}
        true -> build_data(prior, live, unreadable?, window, ctx)
      end
    end
  end

  defp build_data(prior, live, unreadable?, window, ctx) do
    records =
      (prior.records ++ live.records) |> Enum.uniq_by(& &1.record_id) |> Enum.filter(&(DateTime.compare(&1.timestamp, window.end) == :lt)) |> Enum.sort_by(&{&1.timestamp_ms, &1.boot_id, &1.sequence})

    {_actors, tickets, _findings} = Dataset.reduce(records)
    contexts = Map.new(Enum.filter(records, &(&1.kind == "run_context")), &{&1.boot_id, &1.attributes})
    by_ticket = records |> Enum.filter(&(&1.kind == "lifecycle")) |> Enum.group_by(& &1.attributes["ticket"])
    tickets = Map.new(tickets, fn {id, ticket} -> {id, ticket_record(ticket, Map.get(by_ticket, id, []), contexts)} end)
    capacity = (prior.samples ++ live.samples) |> Enum.uniq_by(& &1.record_id) |> capacity(window)
    github = if Map.get(ctx, :include_github, github_needed?(ctx)), do: github_window(window, ctx), else: nil
    required_workflows = Map.get(github || %{}, "required_workflows", Map.get(ctx, :required_workflows, configured_workflows()))
    run_rows = Map.get(github || %{}, "ci_runs", Map.get(github || %{}, "runs"))
    ci_runs = if is_list(run_rows) and required_workflows != [], do: Enum.filter(run_rows, &(&1["name"] in required_workflows)), else: nil
    flake_state = flake_state(ctx)

    {:ok,
     Map.merge(
       %{
         tickets: tickets,
         capacity: capacity,
         earliest_at: earliest_at(records),
         partial?: unreadable? or prior.state != :complete or live.state != :complete,
         accounting: accounting_option(tickets, window, ctx)
       },
       github_data(github, ci_runs, flake_state, records, capacity, window)
     )}
  end

  defp earliest_at(records), do: records |> Enum.map(& &1.timestamp) |> Enum.min(DateTime, fn -> nil end)

  defp github_data(github, ci_runs, flake_state, records, capacity, window) do
    github = github || %{}
    journal_captured? = is_map(flake_state)
    journal = if journal_captured?, do: flake_state, else: %{}

    %{
      ci_runs: ci_runs,
      ci_runs_status: if(is_list(ci_runs), do: :captured, else: :unavailable),
      github_pulls: Map.get(github, "pulls"),
      flake_issues: Map.get(github, "flake_issues", Map.get(github, "incidents")),
      ci_jobs: Map.get(github, "jobs"),
      flake_evidence: if(journal_captured?, do: failure_evidence(journal), else: nil),
      source_partials: source_partials(github, journal, window, journal_captured?),
      facts: github_facts(facts(records, capacity), github, ci_runs, journal_captured?)
    }
  end

  defp github_facts(facts, github, ci_runs, journal_captured?) do
    facts
    |> maybe_fact(is_list(ci_runs), "ci_runs")
    |> maybe_fact(is_list(Map.get(github, "jobs")), "ci_jobs")
    |> maybe_fact(Map.get(github, "pulls", []) != [], "work_kind")
    |> maybe_fact(is_list(Map.get(github, "pulls")), "pulls")
    |> maybe_fact(Map.has_key?(github, "flake_issues") or Map.has_key?(github, "incidents"), "flake_issues")
    |> maybe_fact(journal_captured?, "flake_evidence")
  end

  defp source_partials(github, journal, window, journal_captured?) do
    partials = Enum.filter(~w(runs ci_runs jobs pulls incidents flake_issues), &Map.get(github, &1 <> "_partial", false))

    if journal_captured? and Enum.any?(failure_evidence(journal), &(evidence_in_window?(&1, window) and (not Map.has_key?(&1, "job_failure_set_complete") or not Map.has_key?(&1, "touched")))),
      do: ["flake_evidence" | partials],
      else: partials
  end

  defp evidence_in_window?(row, window) do
    case row["at_ms"] do
      at when is_integer(at) -> at >= DateTime.to_unix(window.start, :millisecond) and at < DateTime.to_unix(window.end, :millisecond)
      _ -> true
    end
  end

  defp failure_evidence(journal) do
    (Map.get(journal, "failure_metric_evidence", []) ++ Map.get(journal, "failure_observations", []))
    |> Enum.uniq_by(&{&1["identity"], &1["pr"], &1["run_url"], &1["job"]})
    |> Enum.map(fn row -> Map.put(row, "quarantined", Map.has_key?(Map.get(journal, "flakes", %{}), "quarantine-pr :: " <> to_string(row["identity"]))) end)
  end

  defp github_needed?(ctx) do
    case Map.get(ctx, :metric_ids) do
      ids when is_list(ids) ->
        Enum.any?(
          ids,
          &(&1 in ~w(ci_run_failure_rate ci_rerun_rate merge_group_failure_rate pr_ci_wall_time ci_queue_wait feature_merge_share innocent_dequeues flaky_failure_rate flake_issues_filed main_red_events))
        )

      _ ->
        true
    end
  end

  defp accounting_option(tickets, window, ctx) do
    if Map.get(ctx, :include_accounting, false), do: accounting(tickets, window, ctx), else: {:error, :accounting_absent}
  end

  defp configured_workflows do
    case Aiur.Config.settings() do
      {:ok, %{merge_policy: %{main_watch: %{workflows: workflows}}}} when is_list(workflows) -> workflows
      _ -> []
    end
  rescue
    _error -> []
  end

  defp flake_state(ctx) do
    case Map.get(ctx, :landing_watch_state_fun, &Journal.state/1).(Map.get(ctx, :landing_watch_options, [])) do
      {:ok, state} -> state
      _error -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp github_window(window, ctx) do
    case Map.fetch(ctx, :github_window) do
      {:ok, %{} = data} ->
        data

      {:ok, _invalid} ->
        nil

      :error ->
        range = %{start: DateTime.to_iso8601(window.start), end: DateTime.to_iso8601(window.end)}
        sources = request_sources(ctx)
        {data, _missing} = Map.get(ctx, :github_window_sources, &RunTelemetry.window_event_sources/4).(Map.get(ctx, :repo, Paths.repo()), sources, range, Map.get(ctx, :github_options, []))
        if data == %{}, do: nil, else: data
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp request_sources(ctx) do
    ids =
      Map.get(
        ctx,
        :metric_ids,
        ~w(ci_run_failure_rate ci_rerun_rate merge_group_failure_rate pr_ci_wall_time ci_queue_wait feature_merge_share innocent_dequeues flaky_failure_rate flake_issues_filed main_red_events)
      )

    ci? = Enum.any?(ids, &(&1 in ~w(ci_run_failure_rate ci_rerun_rate merge_group_failure_rate pr_ci_wall_time ci_queue_wait flaky_failure_rate)))
    jobs? = Enum.any?(ids, &(&1 in ["ci_queue_wait", "flaky_failure_rate"]))
    pulls? = Enum.any?(ids, &(&1 in ["feature_merge_share", "innocent_dequeues"]))
    incidents? = "flake_issues_filed" in ids

    include =
      []
      |> maybe_include(pulls?, "pulls")
      |> maybe_include(ci?, "ci_runs")
      |> maybe_include(jobs?, "jobs")
      |> maybe_include("main_red_events" in ids, "runs")
      |> maybe_include(incidents?, "flake_issues")

    %{
      "base_branch" => Aiur.Config.base_branch(),
      "required_workflows" => configured_workflows(),
      "incident_labels" => [],
      "flake_issue_labels" => if(incidents?, do: ["flake", Aiur.Config.base_branch() <> "-fix"], else: []),
      "include_sources" => include
    }
  end

  defp maybe_include(sources, true, source), do: [source | sources]
  defp maybe_include(sources, false, _source), do: sources

  defp prior_projection(boot, _window, ctx) do
    case Map.fetch(ctx, :prior_loader) do
      {:ok, loader} ->
        {datasets, unreadable?} = loader.(boot)

        {%{
           records: Enum.flat_map(datasets, & &1.records),
           samples: Enum.flat_map(datasets, &(get_in(&1, [:actors, "_daemon", :samples]) || [])),
           state: if(Enum.any?(datasets, &(&1.warnings != [])), do: :partial, else: :complete)
         }, unreadable?}

      :error ->
        opts = Map.get(ctx, :telemetry_reader_options, []) |> Keyword.put(:lifecycle_events, @events) |> Keyword.put(:attribute_keys, @attributes)
        {:ok, projection} = TelemetryHistory.read(boot, Map.put(ctx, :telemetry_reader_options, opts))
        {projection, false}
    end
  end

  defp ticket_record(ticket, raw, contexts) do
    dispatch = Enum.find(ticket.events, &(&1.event == "dispatch"))
    context = if dispatch, do: Map.get(contexts, dispatch.boot_id, %{}), else: %{}
    attrs = if dispatch, do: cohort(dispatch, context), else: %{}

    Map.merge(ticket, %{
      at: if(dispatch, do: dispatch.timestamp_dt),
      attrs: attrs,
      blockers: if(dispatch, do: dispatch.blockers),
      pr_source?: Enum.any?(raw, &true_pr_open?/1),
      pr_opened_at: raw |> Enum.filter(&true_pr_open?/1) |> Enum.map(& &1.timestamp) |> Enum.min(DateTime, fn -> nil end),
      reviews: raw |> Enum.filter(&review?/1) |> Enum.map(& &1.timestamp)
    })
  end

  defp cohort(dispatch, context) do
    attrs = dispatch |> Map.take([:backend, :model, :effort, :feature, :epic, :start_mode]) |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    Map.merge(attrs, %{
      "complexity" => dispatch.complexity,
      "aiur_version" => context["aiur_vsn"],
      "config_hash" => context["config_hash"],
      "tags" => Map.merge(context["capture_tags"] || %{}, if(is_binary(dispatch.work_kind), do: %{"work_kind" => dispatch.work_kind}, else: %{})),
      "feature_tags" => if(dispatch.feature, do: [dispatch.feature])
    })
  end

  defp true_pr_open?(record), do: record.attributes["event"] == "pr_opened" and is_binary(record.attributes["source_timestamp"]) and record.attributes["source"] in ["github", "github_reconciliation"]
  defp review?(record), do: record.attributes["event"] == "comment_received" and record.attributes["author_trusted"] == true and not is_nil(record.attributes["review_thread_id"])

  defp facts(records, capacity) do
    base =
      Enum.flat_map(records, fn record ->
        attrs = record.attributes

        []
        |> maybe_fact(true_pr_open?(record), "pr_opened_source_time")
        |> maybe_fact(review?(record), "review_source")
        |> maybe_fact(attrs["event"] == "dispatch" and is_list(attrs["blockers"]), "blocked_by")
        |> maybe_fact(attrs["event"] == "dispatch" and not is_nil(attrs["epic"]), "epic")
      end)

    base |> maybe_fact(capacity != [], "fleet_activity") |> maybe_fact(Enum.any?(capacity, &is_number(&1.cap)), "fleet_capacity") |> Enum.uniq()
  end

  defp maybe_fact(facts, true, fact), do: [fact | facts]
  defp maybe_fact(facts, false, _fact), do: facts

  # Samples hold for at most one sampling interval; gaps and downtime never become idle or active hours.
  defp capacity(samples, window) do
    samples
    |> Enum.group_by(& &1.boot_id)
    |> Enum.flat_map(fn {_boot, samples} ->
      samples
      |> Enum.sort_by(& &1.timestamp_ms)
      |> Enum.chunk_every(2, 1)
      |> Enum.flat_map(&capacity_sample(&1, window))
    end)
    |> Enum.sort_by(& &1.start, DateTime)
  end

  defp capacity_sample([sample | next], window) do
    at = Common.timestamp(sample.timestamp)
    finish = min_at(if(next == [], do: window.end, else: Common.timestamp(hd(next).timestamp)), DateTime.add(at, 5, :second))
    start = max_at(at, window.start)
    finish = min_at(finish, window.end)
    running = sample["fleet_agents_occupied"]
    cap = sample["fleet_agents_configured"]
    valid = sample.fleet_capacity_status == "current" and is_number(running) and running >= 0
    if valid and DateTime.compare(start, finish) == :lt, do: [%{start: start, end: finish, running: running, cap: cap}], else: []
  end

  defp min_at(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp max_at(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp accounting(tickets, window, ctx) do
    if Map.get(ctx, :accounting_available, Map.has_key?(ctx, :usage_query) or not is_nil(Process.whereis(Aiur.UsageAggregate.Store))) do
      ids =
        tickets
        |> Map.values()
        |> Enum.filter(&(&1.at && Common.in_window?(&1.at, window) && Enum.any?(&1.events, fn e -> e.event == "pr_merged" end)))
        |> Enum.map(& &1.ticket)

      case Map.get(ctx, :identity_lookup, &Aiur.Tracker.fetch_issue_states_by_ids/1).(ids) do
        {:ok, issues} ->
          query = Map.get(ctx, :usage_query, &Aiur.UsageAggregate.query/1)
          snapshot = Map.get(ctx, :usage_snapshot, &Aiur.UsageAggregate.cells_snapshot/0).()
          {:ok, catalog} = RelationshipRegistry.register(Catalog.relationship_catalog(), Relationship.definition())
          by_ticket = Enum.group_by(snapshot.cells, fn {{dims, _measure}, _value} -> dims.ticket end)
          identities = issues |> Enum.map(& &1.tracker_identity) |> Enum.filter(&Aiur.TrackerIdentity.joinable?/1)
          result = query.(%{tickets: identities})
          {:ok, Map.new(issues, fn issue -> {issue.identifier, usage(issue.tracker_identity, result, snapshot, catalog, by_ticket)} end)}

        {:error, reason} ->
          {:error, {:accounting_identity_unavailable, reason}}
      end
    else
      {:error, :accounting_absent}
    end
  catch
    :exit, reason -> {:error, {:accounting_unavailable, reason}}
  end

  defp usage(identity, result, snapshot, catalog, by_ticket) do
    key = Aiur.TrackerIdentity.github_key(identity)
    totals = get_in(result, [:groups, :by_ticket, key])

    complete? =
      result.health == :healthy and result.freshness.status == :fresh and result.aggregate_generation == snapshot.metadata.generation and
        get_in(result, [:coverage, :projection, :partial_records]) == 0 and is_map(totals)

    cond do
      is_nil(key) -> {:error, :accounting_identity_missing}
      not complete? -> {:error, :accounting_incomplete}
      true -> {:ok, Map.put(totals, :token_total, Tokens.total(Map.get(by_ticket, key, []), catalog))}
    end
  end
end

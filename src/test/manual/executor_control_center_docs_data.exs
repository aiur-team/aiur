defmodule Aiur.Docs.ControlCenterFixture.Data do
  alias Aiur.BuildOrder.ProviderHealth

  def now, do: Process.get(:fixture_now)

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

  def unit_number("EX-" <> digits), do: String.to_integer(digits)

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
  def configure_build_order_pack(tmp) do
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
  def build_order_pack do
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

  def build_order_tickets do
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

  def build_order_number("EX-" <> digits), do: String.to_integer(digits)

  # Phases 1-3 are finished, 4 is in flight, 5-7 are still planned — the mix the
  # Build Order graph is designed to show.
  @build_order_completed ~w(EX-401 EX-402 EX-403 EX-404 EX-405 EX-406 EX-407 EX-408 EX-409 EX-410 EX-411)
  @build_order_cancelled ~w(EX-412)

  def build_order_status do
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

  def build_order_plan do
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
end

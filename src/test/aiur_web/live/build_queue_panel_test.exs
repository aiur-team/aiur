defmodule AiurWeb.BuildQueuePanelTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Aiur.BuildOrder.{Catalog, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildQueue.Sources.ProjectionRead
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildQueue.Panel

  defmodule Projection do
    use GenServer
    def start_link(root), do: GenServer.start_link(__MODULE__, root)
    @impl true
    def init(root), do: {:ok, root}
    @impl true
    def handle_call(:catalog, _from, root), do: {:reply, %{root | scope: :catalog, data: %Catalog{entries: [root.data.root]}}, root}
    def handle_call({:selected, _identity}, _from, root), do: {:reply, {:ok, root}, root}
  end

  @now ~U[2026-10-09 08:00:00Z]

  test "loading is visible before the first read" do
    html = render_component(&Panel.panel/1, view: nil, now: @now)
    assert html =~ "Loading build queues"
    assert html =~ ~s(data-queue-state="loading")
  end

  for {status, copy} <- [
        disabled: "Build queue is disabled.",
        unsupported_tracker: "This tracker does not support build queues.",
        store_unavailable: "Queue store unavailable; promotion paused.",
        writes_paused: "Queue writes paused by the GitHub budget.",
        unknown: "Queue readiness unknown."
      ] do
    test "renders #{status} independently" do
      html = render_component(&Panel.panel/1, view: view(unquote(status)), now: @now)
      assert html =~ unquote(copy)
      assert html =~ ~s(data-queue-state="#{unquote(status)}")
    end
  end

  for status <- [:disabled, :unsupported_tracker] do
    test "#{status} shows only its notice, without source or attention placeholders" do
      fixture =
        put_in(view(unquote(status)), [:model, :sources, "tracker_observation"], %{state: :unavailable, observed_at: nil, age_ms: nil, freshness: :unknown, reasons: [:observation_unavailable]})

      html = render_component(&Panel.panel/1, view: fixture, now: @now)
      refute html =~ "data-queue-source"
      refute html =~ "Attentions"
      refute html =~ "Freshness"
      refute html =~ ":observation"
    end
  end

  test "source names and reasons render as words, not Elixir terms" do
    fixture = put_in(view(:running), [:model, :sources, "tracker_observation"], %{state: :unavailable, observed_at: nil, age_ms: nil, freshness: :unknown, reasons: [:observation_unavailable]})
    html = render_component(&Panel.panel/1, view: fixture, now: @now)
    assert html =~ "<strong>Tracker</strong>"
    assert html =~ "Observation unavailable"
    refute html =~ "tracker_observation</strong>"
    refute html =~ "[:"
  end

  test "empty queues show the CLI hint even without an observation" do
    fixture = put_in(view(:running), [:model, :queues], []) |> put_in([:model, :sources], %{})
    html = render_component(&Panel.panel/1, view: fixture, now: @now)
    assert html =~ "No build queues yet."
    assert html =~ "aiur queue add &lt;ids…&gt;"
    assert html =~ ~s(data-queue-state="empty")
  end

  test "unknown source renders unknown age and readiness, never zero or ready" do
    fixture = view(:running) |> put_in([:model, :sources, "tracker_observation"], %{state: :unavailable, observed_at: nil, age_ms: nil, freshness: :unknown, reasons: [:observation_unavailable]})
    fixture = put_in(fixture, [:model, :queues, Access.at(0), :progress], %{completed: nil, total: nil, percent: nil, resolved: nil, resolution: :unknown})
    html = render_component(&Panel.panel/1, view: fixture, now: @now)
    assert html =~ ~s(data-queue-state="unknown")
    assert html =~ "Age: Unknown"
    assert html =~ "Observed: Unknown"
    assert html =~ "Freshness: Unknown"
    assert html =~ ~s(data-queue-progress="unknown">Unknown)
    refute html =~ "0%"
    refute html =~ "Ready for promotion"
    refute html =~ "0s ago"
  end

  test "stale source renders its timestamp and age and dims readiness" do
    fixture = view(:running) |> put_in([:model, :sources, "tracker_observation", :freshness], :stale) |> put_in([:model, :sources, "tracker_observation", :age_ms], 95_000)
    html = render_component(&Panel.panel/1, view: fixture, now: @now)
    assert html =~ ~s(data-queue-state="stale")
    assert html =~ "2026-10-09T08:00:00Z"
    assert html =~ "95s ago"
    assert html =~ ~s(data-readiness-dimmed)
    refute html =~ "Ready for promotion"
  end

  for {state, label} <- [
        waiting: "Waiting",
        ready: "Ready for promotion",
        promoted: "Promoted",
        promoted_unauthorized: "Promoted (unauthorized)",
        claimed: "Claimed",
        held: "Held",
        overridden: "Overridden",
        failed_prerequisite: "Failed prerequisite",
        completed: "Completed",
        cancelled: "Cancelled",
        removed: "Removed",
        unknown: "Unknown"
      ] do
    test "renders item state #{state}" do
      fixture = view(:running) |> put_in([:model, :queues, Access.at(0), :items, Access.at(0), :state], unquote(state))
      html = render_component(&Panel.panel/1, view: fixture, now: @now)
      assert html =~ ~s(data-item-state="#{unquote(state)}")
      chip = html |> Floki.parse_document!() |> Floki.find("[data-queue-item] td .badge") |> Floki.text()
      assert chip == unquote(label)
    end
  end

  test "renders progress, waiting causes, rank and open attentions without controls" do
    html = render_component(&Panel.panel/1, view: view(:running), now: @now)
    assert html =~ "50% · 1/2 completed"
    assert html =~ "#12 · Waiting · Local"
    assert html =~ "2 open downstream · priority 1"
    assert html =~ "Queue hold"
    assert html =~ "Prerequisite failed"
    refute html =~ "<button"
    refute html =~ "phx-click"
  end

  test "resolved attentions expire after sixty seconds and active ones remain" do
    active = %{"needs_attention" => true, "timestamp" => "2026-10-08T08:00:00Z", "message" => "Prerequisite failed"}
    recent = %{"needs_attention" => false, "timestamp" => "2026-10-09T07:59:30Z", "message" => "Prerequisite cleared"}
    old = %{recent | "timestamp" => "2026-10-09T07:58:00Z", "message" => "Old resolution"}
    fixture = %{view(:running) | attentions: [active, recent, old, %{"timestamp" => "invalid", "needs_attention" => false, "message" => "Invalid timestamp"}]}
    html = render_component(&Panel.panel/1, view: fixture, now: @now)
    assert html =~ "Prerequisite failed"
    assert html =~ "Prerequisite cleared"
    assert html =~ ~s(data-queue-attention="resolved")
    assert html =~ "60 seconds"
    refute html =~ "Old resolution"
    refute html =~ "Invalid timestamp"
    expired = render_component(&Panel.panel/1, view: fixture, now: DateTime.add(@now, 61, :second))
    refute expired =~ "Prerequisite cleared"
    assert expired =~ "Prerequisite failed"
  end

  test "one unavailable adopted root does not dim a healthy list queue" do
    fixture = view(:running)
    list = hd(fixture.model.queues)
    root = %{list | queue_id: "q-1234", kind: :build_order, root: 42}
    fixture = put_in(fixture, [:model, :queues], [list, root])
    fixture = put_in(fixture, [:model, :sources, "build_order:42"], %{state: :unavailable, observed_at: nil, age_ms: nil, freshness: :unknown, reasons: [:projection_unavailable]})
    html = render_component(&Panel.panel/1, view: fixture, now: @now)
    document = Floki.parse_document!(html)
    assert html =~ ~s(data-queue-state="unknown")
    assert document |> Floki.find("[data-queue-id='q-abcd'] td .badge") |> Floki.text() == "Ready for promotion"
    assert Floki.find(document, "[data-queue-id='q-abcd'] [data-readiness-dimmed]") == []
    assert document |> Floki.find("[data-queue-id='q-1234'] td .badge") |> Floki.text() == "Unknown"
    assert length(Floki.find(document, "[data-queue-id='q-1234'] [data-readiness-dimmed]")) == 1
  end

  test "adopted root progress renders canonical string resolutions from the real projection reader" do
    identity = %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "ROOT", identifier: "2573"}
    health = %ProviderHealth{state: :healthy, generation: 1, complete?: true, observed_at: @now}
    members = List.duplicate(%Member{lifecycle: %Lifecycle{state: :closed, state_reason: :completed}}, 9)

    for {resolution, resolved, total, percent, expected} <- [
          {:partial, 12, 15, 60, "60% · 9/15 completed · Partial (12/15)"},
          {:resolved, 15, 15, 60, "60% · 9/15 completed · Resolved (15/15)"},
          {:unresolved, 0, 15, nil, "Unresolved"},
          {:empty, 0, 0, nil, "Empty"}
        ] do
      root = %RootSummary{identity: identity, progress: percent, progress_resolution: resolution, progress_resolved_count: resolved, member_count: total}
      snapshot = %Snapshot{scope: {:selected, identity}, repository: {"owner", "repo"}, generation: 1, health: health, data: %SelectedRoot{root: root, members: members, provider: health}}
      server = start_supervised!(Supervisor.child_spec({Projection, snapshot}, id: resolution))
      reading = ProjectionRead.read(2573, DateTime.to_unix(@now, :millisecond), server)
      assert reading.progress.resolution == Atom.to_string(resolution)
      fixture = put_in(view(:running), [:model, :queues, Access.at(0), :progress], reading.progress)
      html = render_component(&Panel.panel/1, view: fixture, now: @now)
      progress = html |> Floki.parse_document!() |> Floki.find("[data-queue-progress]") |> Floki.text()
      assert progress == expected
    end
  end

  defp view(status) do
    item = %{
      number: 13,
      position: 1,
      state: :ready,
      reason: :queue_hold,
      rank: {-2, 1, 1, 0, "13"},
      downstream_open: 2,
      attention: [:prerequisite_failed],
      prerequisites: [%{number: 12, verdict: :waiting, source: :local}]
    }

    queue = %{queue_id: "q-abcd", kind: :list, root: nil, name: "Next", held: true, items: [item], progress: %{completed: 1, total: 2, percent: 50, resolved: 2, resolution: :resolved}}
    source = %{state: :ok, observed_at: @now, age_ms: 0, freshness: :current, reasons: []}
    %{model: %{status: status, sources: %{"tracker_observation" => source}, queues: [queue]}, attentions: []}
  end
end

defmodule AiurWeb.BuildOrder.TicketContextPresenterTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.{Lifecycle, TicketHistory}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}
  alias Aiur.BuildOrder.TicketHistory.Entry
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter

  @observed_at ~U[2026-07-16 12:00:00Z]

  test "presents a bounded, repository-qualified context from normalized snapshots" do
    identity = identity()

    context =
      TicketContextPresenter.present(
        detail_state(identity),
        history(identity, entries: entries(101), truncated?: false),
        capabilities()
      )

    assert context.repository == "owner/repo"
    assert context.identifier == "42"
    assert context.title == "Configured ticket"
    assert context.description == "A bounded description"
    assert context.lifecycle == %{state: :open, reason: :none}
    assert context.detail.state == :available
    assert context.history.state == :available
    assert context.history.freshness == :fresh
    assert context.progress.percent == 40
    assert context.progress.source == :checkin
    assert context.progress.observed_at == @observed_at
    assert context.latest_evidence.source == %{kind: :agent_event, name: "progress.checkin"}
    assert context.latest_evidence.observed_at == @observed_at
    assert length(context.logs.entries) == 100
    assert context.logs.truncated?

    assert context.logs.entries |> hd() |> Map.take([:label, :source, :occurred_at, :observed_at]) == %{
             label: "Progress updated",
             source: :exchange,
             occurred_at: @observed_at,
             observed_at: @observed_at
           }

    assert Enum.map(context.capabilities, &{&1.kind, &1.label, &1.available?}) == [
             {:github, "Issue", true},
             {:github, "Pull request", false},
             {:chat, "Chat", true},
             {:commands, "Commands", false}
           ]

    assert Enum.at(context.capabilities, 1).href == nil
    assert Enum.at(context.capabilities, 1).reason == "Pull request has not been opened."
    refute Map.has_key?(context, :root)
    refute Map.has_key?(context, :membership)
    refute Map.has_key?(context, :adjacency)
    refute Map.has_key?(context, :edge)
    refute Map.has_key?(context, :readiness)
  end

  test "keeps detail and history degradation states distinct" do
    identity = identity()

    for {detail, expected_detail} <- [
          {%State{identity: identity, generation: 1, health: :healthy, detail: nil}, :missing},
          {%State{identity: identity, generation: 1, health: :stale, detail: snapshot(identity)}, :stale},
          {%State{identity: identity, generation: 1, health: :unavailable, failure: %Failure{kind: :permission}}, :unavailable}
        ] do
      assert TicketContextPresenter.present(detail, history(identity), []).detail.state == expected_detail
    end

    for state <- [:known_empty, :missing_source, :restart_unknown, :stale, :unavailable] do
      assert TicketContextPresenter.present(detail_state(identity), history(identity, health: state), []).history.state == state
    end
  end

  test "keeps every bounded Logs cardinality explicit" do
    identity = identity()

    for count <- [0, 1, 50, 100] do
      context = TicketContextPresenter.present(detail_state(identity), history(identity, entries: entries(count)), [])

      assert length(context.logs.entries) == count
      refute context.logs.truncated?
    end
  end

  test "does not join mismatched repository snapshots or expose raw failure data" do
    detail_identity = identity()
    foreign_history = history(identity(owner: "other"), health: :available, entries: entries(1))

    context =
      TicketContextPresenter.present(
        %State{
          identity: detail_identity,
          generation: 1,
          health: :unavailable,
          failure: %Failure{kind: :transport, retry_after: 59}
        },
        foreign_history,
        [%{kind: :unknown, available?: true, href: "https://example.test/raw"}]
      )

    assert context.repository == "owner/repo"
    assert context.history.state == :unavailable
    assert context.logs.entries == []
    assert context.capabilities == []
    refute inspect(context) =~ "retry_after"
    refute inspect(context) =~ "example.test/raw"
  end

  test "does not render arbitrary Log labels or details from a normalized-history lookalike" do
    identity = identity()

    raw_log = %Entry{
      event_id: 9,
      kind: :progress,
      label: "secret output from /home/private/agent.ndjson",
      source: :issue_log,
      occurred_at: @observed_at,
      observed_at: @observed_at,
      details: %{raw: "secret output from /home/private/agent.ndjson"}
    }

    context = TicketContextPresenter.present(detail_state(identity), history(identity, entries: [raw_log]), [])

    assert [
             %{
               kind: :progress,
               label: "Progress updated",
               source: :issue_log,
               occurred_at: @observed_at,
               observed_at: @observed_at
             }
           ] = context.logs.entries

    refute inspect(context) =~ "/home/private"
    refute inspect(context) =~ "agent.ndjson"
  end

  test "does not retain unsafe evidence or provenance from a malformed cached snapshot" do
    identity = identity()

    context =
      TicketContextPresenter.present(
        detail_state(identity),
        history(identity,
          progress: %{status: :known, percent: 40, source: :checkin, provenance: %{run_id: "/home/private/run"}},
          latest_evidence: %{status: :known, source: %{kind: :agent_event, name: "raw output /home/private"}}
        ),
        []
      )

    assert context.progress.provenance == %{}
    assert context.latest_evidence.source == nil
    refute inspect(context) =~ "/home/private"
  end

  test "fails closed on oversized descriptions and makes unsafe or incomplete CTAs unavailable" do
    identity = identity()
    oversized = String.duplicate("description ", 1_000)
    detail = detail_state(identity, description: oversized)

    context =
      TicketContextPresenter.present(detail, history(identity), [
        %{kind: :github, variant: :issue, available?: true, href: "javascript:alert(1)"},
        %{kind: :chat, available?: true, href: "//other.example/chat"},
        %{kind: :commands, available?: true, href: "/\\evil.example/commands"}
      ])

    assert context.description == nil
    assert Enum.map(context.capabilities, & &1.label) == ["Issue", "Chat", "Commands"]
    assert Enum.all?(context.capabilities, &(!&1.available? and is_nil(&1.href)))
    assert Enum.all?(context.capabilities, &(is_binary(&1.reason) and &1.reason != ""))
  end

  test "sanitizes malformed typed detail snapshots before presenting visible text" do
    identity = identity()

    context =
      TicketContextPresenter.present(
        detail_state(identity,
          title: "Authorization: Bearer raw-title-secret",
          description: "Captured from /home/private/agent.log with password: raw-description-secret"
        ),
        history(identity),
        []
      )

    refute context.title =~ "raw-title-secret"
    refute context.description =~ "/home/private"
    refute context.description =~ "raw-description-secret"
    refute inspect(context) =~ "raw-title-secret"
    refute inspect(context) =~ "raw-description-secret"
  end

  test "only keeps GitHub destinations for the configured repository and destination type" do
    identity = identity()

    valid_context =
      TicketContextPresenter.present(detail_state(identity), history(identity), [
        %{kind: :github, variant: :issue, available?: true, href: "https://github.com/owner/repo/issues/42"},
        %{kind: :github, variant: :pull_request, number: 7, available?: true, href: "https://github.com/owner/repo/pull/7"}
      ])

    assert Enum.map(valid_context.capabilities, &{&1.label, &1.href, &1.available?}) == [
             {"Issue", "https://github.com/owner/repo/issues/42", true},
             {"Pull request", "https://github.com/owner/repo/pull/7", true}
           ]

    for href <- ["http://github.com/owner/repo/issues/42", "https://github.com/other/repo/issues/42"] do
      [capability] =
        TicketContextPresenter.present(detail_state(identity), history(identity), [
          %{kind: :github, variant: :issue, available?: true, href: href}
        ]).capabilities

      refute capability.available?
      assert capability.href == nil
      assert capability.reason == "Issue is unavailable."
    end
  end

  defp detail_state(identity, overrides \\ []) do
    %State{
      identity: identity,
      generation: 1,
      health: :healthy,
      detail: snapshot(identity, overrides),
      last_success_at: @observed_at,
      last_attempt_at: @observed_at
    }
  end

  defp snapshot(identity, overrides \\ []) do
    struct!(
      Snapshot,
      Keyword.merge(
        [
          identity: identity,
          title: "Configured ticket",
          description: "A bounded description",
          lifecycle: Lifecycle.from_github("OPEN", nil),
          url: "https://github.com/owner/repo/issues/42",
          destinations: nil,
          created_at: @observed_at,
          updated_at: @observed_at,
          observed_at: @observed_at
        ],
        overrides
      )
    )
  end

  defp history(identity, overrides \\ []) do
    struct!(
      TicketHistory.Snapshot,
      Keyword.merge(
        [
          identity: identity,
          generation: 1,
          health: :available,
          status_label: "Current activity",
          progress: %{
            status: :known,
            percent: 40,
            source: :checkin,
            observed_at: @observed_at,
            provenance: %{run_id: "run-42"}
          },
          latest_evidence: %{
            status: :known,
            source: %{kind: :agent_event, name: "progress.checkin"},
            observed_at: @observed_at
          },
          entries: [],
          truncated?: false,
          observed_at: @observed_at,
          freshness: :fresh,
          source_health: %{activity: :available, history: :available}
        ],
        overrides
      )
    )
  end

  defp entries(count) do
    for event_id <- if(count == 0, do: [], else: 1..count) do
      %Entry{
        event_id: event_id,
        kind: :progress,
        label: "Progress updated",
        source: :exchange,
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{run_id: "run-42"},
        details: %{percent: 40}
      }
    end
  end

  defp capabilities do
    [
      %{kind: :github, variant: :issue, available?: true, href: "https://github.com/owner/repo/issues/42"},
      %{kind: :github, variant: :pull_request, available?: false, reason: :not_opened},
      %{kind: :chat, available?: true, href: "/chat/42"},
      %{kind: :commands, available?: false, reason: :not_available}
    ]
  end

  defp identity(overrides \\ []) do
    struct!(
      TrackerIdentity,
      Keyword.merge(
        [
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "I42",
          identifier: "42",
          reason: nil
        ],
        overrides
      )
    )
  end
end

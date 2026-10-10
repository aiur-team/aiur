defmodule Aiur.BrowserHarness.UnitsLive.Data do
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capability, View}

  alias Aiur.OpenTicketSource.Snapshot, as: OpenTicketSnapshot

  alias AiurWeb.OperatorControlCenter.{
    AgentRoutingPreview,
    DecisionPath,
    TicketsPresenter
  }

  @now ~U[2026-07-17 12:00:00Z]

  def tickets_view do
    TicketsPresenter.project(%OpenTicketSnapshot{
      status: :available,
      generation: 1,
      observed_at: @now,
      tickets: [
        ticket("2101", "Unrouted backlog ticket", ["complexity:3"]),
        ticket("2102", "Documentation refresh", [], "The reference pages drifted after the retry storm work.")
      ]
    })
  end

  def ticket(identifier, title, labels, body_excerpt \\ nil) do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "acme",
        repository: "aiur",
        provider_id: "NODE-#{identifier}",
        identifier: identifier,
        reason: nil
      },
      identifier: identifier,
      title: title,
      body_excerpt: body_excerpt,
      url: "https://github.com/acme/aiur/issues/#{identifier}",
      state: "Todo",
      labels: labels,
      assignee: nil,
      created_at: ~U[2026-07-16 12:00:00Z],
      updated_at: ~U[2026-07-17 11:00:00Z]
    }
  end

  def add_agent_modal(row) do
    selection =
      AgentRoutingPreview.normalize_selection(%{
        backend: row.routing.backend,
        # Mirrors `DashboardLive.add_agent_modal/1`: the model select opens on the
        # model that will actually run, not on the possibly-nil requested one.
        model: row.routing.model || row.routing.resolved_model,
        effort: row.routing.effort,
        complexity: row.routing.complexity
      })

    %{
      token: row.token,
      identifier: row.identifier,
      title: row.title,
      identity: row.identity,
      routing: row.routing,
      selection: selection,
      options: AgentRoutingPreview.options(selection.backend),
      labels: row.labels,
      plan: AgentRoutingPreview.plan(selection, row.labels),
      pending?: false,
      result: nil
    }
  end

  def mount_catalog(%{"catalog" => "empty"}) do
    # Match what UnitsPresenter actually derives for a catalog with no rows, so
    # the harness exercises the real zero-unit status rather than `:ready` with
    # an empty list — a shape production never produces.
    %{catalog([]) | status: :empty, message: "No units in this run yet."}
  end

  def mount_catalog(_params), do: catalog(rows())

  def catalog(rows) do
    %{
      status: :ready,
      message: nil,
      snapshot: %{
        rows: rows,
        health: %{membership: :available},
        freshness: %{membership: %{status: :fresh}}
      }
    }
  end

  def update_catalog(catalog, fun) do
    put_in(catalog, [:snapshot, :rows], fun.(catalog.snapshot.rows))
  end

  def update_primary_row(rows) do
    Enum.map(rows, fn
      %{identity: %{identifier: "1110"}} = row ->
        row
        |> Map.put(:title, "Responsive Units interface · updated")
        |> Map.put(:progress, %{status: :known, percent: 60, source: :checkin, freshness: :fresh})

      row ->
        row
    end)
  end

  def rows do
    [
      row(identity("NODE-1110", "1110"), %{
        title: "Responsive Units interface",
        lifecycle: :active,
        runtime: runtime(:running, :working, :active, 4_200),
        progress: %{status: :known, percent: 50, source: :checkin, freshness: :fresh},
        latest_evidence: %{status: :known, source: %{kind: :branch, name: "feature pushed"}},
        live_conversation: %{
          generation_handle: "conversation:" <> String.duplicate("a", 43),
          state: :live,
          health: :healthy,
          freshness: :current
        }
      }),
      row(identity("NODE-1111", "1111"), %{
        title: "Paused provider follow-up",
        lifecycle: :active,
        runtime: runtime(:running, :paused, :waiting_for_human, 900),
        reasons: reasons(:waiting_for_human, :waiting_for_human, :open_command, :operator_pause, nil),
        open_command_count: 1,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown}
      }),
      row(identity("NODE-1112", "1112"), %{
        title: "Queued integration",
        lifecycle: :queued,
        runtime: runtime(:retrying, :retrying, :backing_off, 0),
        reasons: reasons(:backing_off, nil, nil, nil, :backing_off),
        requested_model: nil,
        resolved_model: nil,
        effort: nil,
        complexity: nil,
        build_lane: nil,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown}
      }),
      row(identity("NODE-1113", "1113"), %{
        title: "Finished accessibility evidence",
        lifecycle: :terminal,
        terminal?: true,
        runtime: runtime(:idle, :completed, :none, 7_200),
        progress: %{status: :known, percent: 100, source: :phase, freshness: :stale},
        latest_evidence: %{status: :known, source: %{kind: :pull_request, name: "merged"}}
      })
    ] ++
      Enum.map(1114..1116, fn number ->
        row(identity("NODE-#{number}", to_string(number)), %{
          title: "Queued integration #{number}",
          lifecycle: :queued,
          runtime: runtime(:retrying, :retrying, :backing_off, 0),
          reasons: reasons(:backing_off, nil, nil, nil, :backing_off),
          requested_model: nil,
          resolved_model: nil,
          effort: nil,
          complexity: nil,
          build_lane: nil,
          progress: %{status: :unknown},
          latest_evidence: %{status: :unknown}
        })
      end)
  end

  def conversation_snapshot(reply \\ :without_reply) do
    messages =
      [
        %{
          id: "fixture-message",
          role: "agent",
          title: "Assistant",
          body: "Conversation drawer hook is running.",
          occurred_at: @now,
          observed_at: @now
        }
      ] ++ conversation_reply(reply)

    %{
      state: :live,
      health: :healthy,
      freshness: :current,
      messages: messages,
      observed_at: @now,
      truncated?: false,
      evicted_count: 0,
      source: %{worker_generation: 1, session_id: "fixture-session"}
    }
  end

  def conversation_reply(:without_reply), do: []

  def conversation_reply(:with_partial_reply) do
    [
      %{
        id: "fixture-voice-reply",
        role: "agent",
        title: "Assistant",
        body: "Voice reply",
        complete?: false,
        occurred_at: @now,
        observed_at: @now
      }
    ]
  end

  def conversation_reply(:with_reply) do
    [
      %{
        id: "fixture-voice-reply",
        role: "agent",
        title: "Assistant",
        body: "Voice reply from the agent.",
        complete?: true,
        occurred_at: @now,
        observed_at: @now
      }
    ]
  end

  def row(identity, overrides) do
    Map.merge(
      %{
        identity: identity,
        title: "Unit #{identity.identifier}",
        url: "https://github.com/its-everdred/aiur/issues/#{identity.identifier}",
        lifecycle: :active,
        terminal?: false,
        replacement_boundary?: false,
        tracker_state: "in-progress",
        backend: :codex,
        agent_family: :codex,
        requested_model: "gpt-5.6-terra",
        resolved_model: nil,
        effort: :high,
        account: nil,
        complexity: 3,
        build_lane: "L2",
        reasons: reasons(:active, nil, nil, nil, nil),
        runtime: runtime(:running, :working, :active, 60),
        timestamps: %{started_at: "2026-07-17T11:00:00Z"},
        open_command_count: 0,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown},
        provider_health: %{
          membership: :available,
          status: :available,
          activity: :available,
          decisions: :available,
          issue: :available
        },
        field_sources: %{},
        sources: %{}
      },
      overrides
    )
  end

  def runtime(bucket, work_state, waiting_reason, seconds) do
    %{
      bucket: bucket,
      work_state: work_state,
      waiting_reason: waiting_reason,
      tracker_paused?: work_state == :paused,
      runtime_seconds: seconds,
      stale_for_seconds: 0,
      membership_lifecycle: :active
    }
  end

  def reasons(waiting, blocking, alert, pause, stuck) do
    %{waiting: waiting, blocking: blocking, alert: alert, pause: pause, stuck: stuck}
  end

  def identity(provider_id, identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end

  def context(row) do
    %View{
      identity: row.identity,
      repository: "its-everdred/aiur",
      identifier: row.identity.identifier,
      title: row.title,
      description: "Bounded ticket context from the accepted shared presentation.",
      lifecycle: %{state: :open, reason: :none},
      detail: %{state: :available, observed_at: @now, last_success_at: @now, last_attempt_at: @now},
      history: %{
        state: :available,
        freshness: :fresh,
        observed_at: @now,
        source_health: %{activity: :available, history: :available}
      },
      progress: Map.merge(%{occurred_at: @now, observed_at: @now, provenance: %{}}, row.progress),
      latest_evidence: Map.merge(%{occurred_at: @now, observed_at: @now, provenance: %{}}, row.latest_evidence),
      logs: %{entries: [], truncated?: false, observed_at: @now},
      capabilities: [
        %Capability{
          kind: :github,
          variant: :issue,
          label: "Issue",
          href: row.url,
          available?: true,
          external?: true
        },
        %Capability{kind: :chat, label: "Chat", available?: false, external?: false, reason: "Chat is unavailable."},
        %Capability{
          kind: :commands,
          label: "Commands",
          href: DecisionPath.inbox(:all, %{ticket: row.identity.identifier}),
          available?: true,
          external?: false
        }
      ]
    }
  end
end

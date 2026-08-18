defmodule AiurWeb.OperatorControlCenter.TicketContextTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capability, LogEntry, View}
  alias AiurWeb.OperatorControlCenter.TicketContext

  @observed_at ~U[2026-07-16 12:00:00Z]

  test "renders a semantic, navigation-only ticket dialog with bounded Logs" do
    html =
      render_component(&TicketContext.ticket_context/1, %{
        id: "ticket-context-42",
        context: context(),
        close_event: "close-ticket-context",
        fallback_focus_id: "units-title",
        focus_key: "navigation-5",
        origin_id: "unit-inspect-owner-repo-42"
      })

    assert html =~ ~s(id="ticket-context-42")
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(phx-hook="TicketContextDialog")
    assert html =~ ~s(data-close-event="close-ticket-context")
    assert html =~ ~s(data-focus-fallback-id="units-title")
    assert html =~ ~s(data-focus-key="navigation-5")
    assert html =~ ~s(data-origin-id="unit-inspect-owner-repo-42")
    assert html =~ ~s(data-dialog-heading)
    assert html =~ ~s(tabindex="-1")
    assert html =~ "owner/repo"
    assert html =~ "Configured ticket"
    assert html =~ "Open — None"
    assert html =~ "40%"
    assert html =~ "Checkin"
    refute html =~ "Run id"
    refute html =~ "run-42"
    refute html =~ "Latest evidence"
    refute html =~ "Session id"
    assert html =~ "Last activity"
    assert html =~ "0 linked tickets"
    assert html =~ "Logs are truncated to the newest safe entries."
    assert html =~ ~s(<table id="ticket-context-42-title-logs-table" class="ticket-context-logs")
    assert html =~ "Activity"
    assert html =~ "Detail"
    assert html =~ "40% complete"
    assert html =~ "<details>"
    assert html =~ ~s(<time datetime="2026-07-16T12:00:00Z")
    # Available destinations are now header CTAs.
    assert html =~ "ticket-context-cta"
    assert html =~ "Open in GitHub"
    assert html =~ "Read chat"
    assert html =~ ~s(href="https://github.com/owner/repo/issues/42")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(href="/chat/42")
    # Unavailable destinations still disclose their reason.
    assert html =~ ~s(aria-disabled="true")
    assert html =~ "Pull request has not been opened."
    assert html =~ "Commands are unavailable."
    assert html =~ ~s(phx-click="close-ticket-context")
    refute html =~ ~s(phx-click="open-chat")
    refute html =~ ~s(phx-click="pause-agent")
    refute html =~ ~s(phx-click="retry")
  end

  test "drops unsafe focus restoration identifiers at the component boundary" do
    html =
      render_component(&TicketContext.ticket_context/1, %{
        id: "ticket-context-unsafe-focus",
        context: context(),
        close_event: "close-ticket-context",
        fallback_focus_id: "unsafe id",
        focus_key: "Bearer secret-token",
        origin_id: "<script>"
      })

    refute html =~ "unsafe id"
    refute html =~ "secret-token"
    refute html =~ "&lt;script&gt;"
    refute html =~ ~s(data-focus-fallback-id=)
    refute html =~ ~s(data-focus-key=)
    refute html =~ ~s(data-origin-id=)
  end

  test "renders region mode without projection-health narration" do
    for {detail, history} <- [
          {:missing, :known_empty},
          {:stale, :stale},
          {:unavailable, :restart_unknown},
          {:unavailable, :unavailable}
        ] do
      html =
        render_component(&TicketContext.ticket_context/1, %{
          id: "ticket-context-state-#{detail}-#{history}",
          context: context(detail: detail, history: history),
          mode: :region
        })

      assert html =~ ~s(role="region")
      refute html =~ ~s(aria-modal="true")
      refute html =~ ~s(phx-hook="TicketContextDialog")
      refute html =~ "Ticket detail"
      refute html =~ "Ticket history"
      refute html =~ "Activity continuity"
    end
  end

  test "degrades a dialog without a valid close callback to a labelled region" do
    html = render_component(&TicketContext.ticket_context/1, %{id: "ticket-context-without-close", context: context()})

    assert html =~ ~s(role="region")
    refute html =~ ~s(role="dialog")
    refute html =~ ~s(aria-modal="true")
    refute html =~ ~s(phx-hook="TicketContextDialog")
    refute html =~ ">Close</button>"
  end

  test "revalidates supplied capabilities before rendering a navigation link" do
    unsafe_capability = %Capability{
      kind: :github,
      variant: :issue,
      label: "Issue",
      href: "javascript:alert(1)",
      available?: true,
      external?: true
    }

    html =
      render_component(&TicketContext.ticket_context/1, %{
        id: "ticket-context-unsafe-capability",
        context: %{context() | capabilities: [unsafe_capability]},
        mode: :region
      })

    refute html =~ "javascript:alert"
    refute html =~ ~s(href="javascript:)
    assert html =~ ~s(aria-disabled="true")
    assert html =~ "Issue is unavailable."
  end

  test "renders blocked-by and blocking dependency tags as non-clickable pills" do
    context = %{
      context()
      | dependencies: %{
          blocked_by: [%{identifier: "41", title: "Upstream task"}],
          blocking: [%{identifier: "43", title: "Downstream task"}]
        }
    }

    html = render_component(&TicketContext.ticket_context/1, %{id: "ticket-context-deps", context: context, mode: :region})

    assert html =~ "Dependencies"
    assert html =~ "Blocked by"
    assert html =~ "Blocking"
    assert html =~ "Upstream task"
    assert html =~ "Downstream task"
    assert html =~ "ticket-context-dep-tag"
    # Non-clickable per follow-up (#1270): no goto/navigation wiring yet.
    refute html =~ ~s(data-goto)
    refute html =~ ~s(phx-click="inspect-unit")
  end

  test "omits the Dependencies section when the ticket has no relationships" do
    html = render_component(&TicketContext.ticket_context/1, %{id: "ticket-context-no-deps", context: context(), mode: :region})

    refute html =~ "ticket-context-dependencies"
  end

  test "renders a fixed header nav with the ticket id, a smaller title, and an X close button" do
    html =
      render_component(&TicketContext.ticket_context/1, %{
        id: "ticket-context-header",
        context: context(),
        close_event: "close-ticket-context"
      })

    assert html =~ ~s(class="ticket-context-nav")
    assert html =~ ~s(class="ticket-context-id mono">#42</span>)
    assert html =~ ~s(class="ticket-context-title")
    assert html =~ "Configured ticket"
    assert html =~ ~s(class="ticket-context-close")
    assert html =~ ~s(aria-label="Close ticket context")
    assert html =~ ~s(phx-click="close-ticket-context")
    assert html =~ ~s(<path d="M6 18 18 6M6 6l12 12">)
    refute html =~ ">Close</button>"
  end

  test "renders the description as height-constrained, scrollable markdown" do
    context = %{
      context()
      | description: "## Overview\n\n- first\n- second\n\n**bold** and `code` with [a link](https://example.com)"
    }

    html = render_component(&TicketContext.ticket_context/1, %{id: "ticket-context-markdown", context: context, mode: :region})

    assert html =~ ~s(class="ticket-context-markdown")
    assert html =~ "<h2>Overview</h2>"
    assert html =~ "<ul>"
    assert html =~ "<li>first</li>"
    assert html =~ "<li>second</li>"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<code>code</code>"
    assert html =~ ~s(href="https://example.com")
    refute html =~ "javascript:"
  end

  test "unifies progress updates and the full event stream in a scrollable Logs view" do
    context = %{
      context()
      | logs: %{
          entries: [
            %LogEntry{
              kind: :pull_request,
              label: "Pull request updated",
              source: :issue_log,
              occurred_at: @observed_at,
              observed_at: @observed_at
            },
            %LogEntry{
              kind: :progress,
              label: "Progress updated",
              source: :exchange,
              occurred_at: @observed_at,
              observed_at: @observed_at,
              details: %{percent: 25}
            }
          ],
          truncated?: false,
          observed_at: @observed_at
        }
    }

    html =
      render_component(&TicketContext.ticket_context/1, %{
        id: "ticket-context-unified-logs",
        context: context,
        mode: :region
      })

    assert html =~ "Progress update"
    assert html =~ "40% complete"
    assert html =~ "Pull request updated"
    assert html =~ "25% complete"
    assert html =~ ~s(class="ticket-context-progress-row")
    assert html =~ ~s(class="ticket-context-logs-wrap")
  end

  test "normalizes direct View inputs before rendering text, logs, evidence, or provenance" do
    unsafe_context = %{
      context()
      | title: "Authorization: Bearer raw-title-secret",
        description: "Captured from /home/private/agent.log with password: raw-description-secret",
        progress: %{context().progress | provenance: %{run_id: "/home/private/run"}},
        latest_evidence: %{
          context().latest_evidence
          | source: %{kind: :agent_event, name: "raw /home/private/evidence"},
            provenance: %{session_id: "/home/private/session"}
        },
        logs: %{
          context().logs
          | entries: [
              %LogEntry{
                kind: :progress,
                label: "raw output from /home/private/agent.ndjson",
                source: :exchange,
                occurred_at: @observed_at,
                observed_at: @observed_at
              }
            ]
        }
    }

    html = render_component(&TicketContext.ticket_context/1, %{id: "ticket-context-unsafe-view", context: unsafe_context, mode: :region})

    refute html =~ "raw-title-secret"
    refute html =~ "raw-description-secret"
    refute html =~ "/home/private"
    refute html =~ "raw output"
    assert html =~ "Progress updated"
    refute html =~ "Latest evidence"
  end

  defp context(overrides \\ []) do
    detail_state = Keyword.get(overrides, :detail, :available)
    history_state = Keyword.get(overrides, :history, :available)

    %View{
      identity: identity(),
      repository: "owner/repo",
      identifier: "42",
      title: "Configured ticket",
      description: "A bounded description",
      lifecycle: %{state: :open, reason: :none},
      detail: %{
        state: detail_state,
        observed_at: @observed_at,
        last_success_at: @observed_at,
        last_attempt_at: @observed_at
      },
      history: %{
        state: history_state,
        freshness: if(history_state == :stale, do: :stale, else: :fresh),
        observed_at: @observed_at,
        source_health: %{activity: :available, history: :available}
      },
      progress: %{
        status: :known,
        percent: 40,
        source: :checkin,
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{run_id: "run-42"}
      },
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress.checkin"},
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{}
      },
      logs: %{
        entries: [
          %LogEntry{
            kind: :progress,
            label: "Progress updated",
            source: :exchange,
            occurred_at: @observed_at,
            observed_at: @observed_at,
            details: %{percent: 40}
          }
        ],
        truncated?: true,
        observed_at: @observed_at
      },
      capabilities: [
        %Capability{kind: :github, variant: :issue, label: "Issue", href: "https://github.com/owner/repo/issues/42", available?: true, external?: true},
        %Capability{kind: :github, variant: :pull_request, label: "Pull request", available?: false, external?: false, reason: "Pull request has not been opened."},
        %Capability{kind: :chat, label: "Chat", href: "/chat/42", available?: true, external?: false},
        %Capability{kind: :commands, label: "Commands", available?: false, external?: false, reason: "Commands are unavailable."}
      ]
    }
  end

  defp identity do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I42",
      identifier: "42",
      reason: nil
    }
  end
end

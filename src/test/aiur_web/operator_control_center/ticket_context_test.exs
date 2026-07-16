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
        close_event: "close-ticket-context"
      })

    assert html =~ ~s(id="ticket-context-42")
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(phx-hook="TicketContextDialog")
    assert html =~ ~s(data-close-event="close-ticket-context")
    assert html =~ ~s(data-dialog-heading)
    assert html =~ ~s(tabindex="-1")
    assert html =~ "owner/repo"
    assert html =~ "Configured ticket"
    assert html =~ "Open — None"
    assert html =~ "40%"
    assert html =~ "Checkin"
    assert html =~ "Progress occurred:"
    assert html =~ "Progress observed:"
    assert html =~ "Run id"
    assert html =~ "run-42"
    assert html =~ "Latest evidence: Agent event / progress.checkin"
    assert html =~ "Evidence occurred:"
    assert html =~ "Evidence observed:"
    assert html =~ "Logs are truncated to the newest safe entries."
    assert html =~ ~s(<ol class="ticket-context-logs")
    assert html =~ ~s(<time datetime="2026-07-16T12:00:00Z")
    assert html =~ ~s(href="https://github.com/owner/repo/issues/42")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(href="/chat/42")
    assert html =~ ~s(aria-disabled="true")
    assert html =~ "Pull request has not been opened."
    assert html =~ "Commands are unavailable."
    assert html =~ ~s(phx-click="close-ticket-context")
    refute html =~ ~s(phx-click="open-chat")
    refute html =~ ~s(phx-click="pause-agent")
    refute html =~ ~s(phx-click="retry")
  end

  test "renders region mode and truthful missing, stale, restart, and unavailable states" do
    for {detail, history, expected} <- [
          {:missing, :known_empty, "Ticket detail has not been loaded."},
          {:stale, :stale, "Ticket detail is stale."},
          {:unavailable, :restart_unknown, "Activity continuity is unknown after restart."},
          {:unavailable, :unavailable, "Ticket history is unavailable."}
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
      assert html =~ expected
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
    assert html =~ "Latest evidence is unknown."
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
      detail: %{state: detail_state, observed_at: @observed_at, last_success_at: @observed_at, last_attempt_at: @observed_at},
      history: %{
        state: history_state,
        freshness: if(history_state == :stale, do: :stale, else: :fresh),
        observed_at: @observed_at,
        source_health: %{activity: :available, history: :available}
      },
      progress: %{status: :known, percent: 40, source: :checkin, occurred_at: @observed_at, observed_at: @observed_at, provenance: %{run_id: "run-42"}},
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress.checkin"},
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{}
      },
      logs: %{
        entries: [%LogEntry{kind: :progress, label: "Progress updated", source: :exchange, occurred_at: @observed_at, observed_at: @observed_at}],
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

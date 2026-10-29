defmodule Aiur.GitHub.CorrectiveProvenanceDispatchTest do
  use ExUnit.Case, async: false

  import Aiur.GitHub.DispatchAuthorization.TestFixtures
  alias Aiur.Commands.{CorrectiveProvenance, CorrectiveTicketBody}
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.Tracker.DispatchProvenance

  setup do
    old = Application.fetch_env(:aiur, :dispatch_provenance)
    Application.delete_env(:aiur, :dispatch_provenance)
    DispatchAuthorization.clear_cache()

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:aiur, :dispatch_provenance, value)
        :error -> Application.delete_env(:aiur, :dispatch_provenance)
      end

      DispatchAuthorization.clear_cache()
    end)

    ticket = %{identifier: "42", url: "https://github.com/owner/repo/issues/42"}
    record = %{action_id: "override-one", corrective_ticket: ticket}
    issue = issue(creator_login: "daemon[bot]", description: CorrectiveTicketBody.marker(record.action_id), url: ticket.url)
    %{issue: issue, decisions: [%{overrides: [record]}]}
  end

  test "local provenance requires a durable exact ticket link and daemon label history", ctx do
    DispatchProvenance.register(:corrective_ticket, &CorrectiveProvenance.authorized?(&1, ctx.decisions))
    assert authorize(ctx.issue).dispatch_authorized?
    refute authorize(%{ctx.issue | id: "43"}).dispatch_authorized?
    refute authorize(%{ctx.issue | url: "https://github.com/other/repo/issues/42"}).dispatch_authorized?
    refute authorize(%{ctx.issue | creator_login: "outsider"}).dispatch_authorized?
    refute authorize(%{ctx.issue | description: "<!-- aiur-command-override:forged -->"}).dispatch_authorized?
    refute authorize(%{ctx.issue | description: ctx.issue.description <> ctx.issue.description}).dispatch_authorized?
    refute authorize(ctx.issue, ["outsider", "daemon[bot]"]).dispatch_authorized?
    refute CorrectiveProvenance.authorized?(ctx.issue, [])
    refute CorrectiveProvenance.check(ctx.issue, :nonexistent_corrective_store)
  end

  test "corrective and existing provenance owners coexist and dead owners confer no authority", ctx do
    DispatchProvenance.register(fn issue -> issue.id == "experiment" end)
    DispatchProvenance.register(:corrective_ticket, &CorrectiveProvenance.authorized?(&1, ctx.decisions))
    assert DispatchProvenance.authorized?(%{ctx.issue | id: "experiment"})
    assert DispatchProvenance.authorized?(ctx.issue)
    DispatchProvenance.register(fn _issue -> false end)
    assert DispatchProvenance.authorized?(ctx.issue)
    owner = spawn(fn -> DispatchProvenance.register(:corrective_ticket, fn _issue -> true end) end)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 1_000
    refute DispatchProvenance.authorized?(ctx.issue)
  end

  defp authorize(issue, actors \\ ["daemon[bot]"]) do
    DispatchAuthorization.clear_cache()
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    events = actors |> Enum.with_index(1) |> Enum.map(fn {actor, index} -> labeled_event(index, "agent:todo", actor, at) end)
    authorize_with_events(issue, events, ["operator"], daemon_account: "daemon[bot]", bot_account: "agent-bot")
  end
end

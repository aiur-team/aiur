defmodule Aiur.VoiceConverse.Host.BriefingSourceTest do
  use Aiur.TestSupport

  alias Aiur.TrackerIdentity
  alias Aiur.VoiceConverse.Host.{BriefingSource, Worker}
  alias VoiceConverse.Briefing

  defmodule Snapshot do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    root = Aiur.TestSupport.tmp_root!("voice-briefing-source")
    identity = identity()
    row = status_row(identity)
    orchestrator = start_supervised!({Snapshot, %{running: [row], retrying: [], idle: []}})
    %{root: root, identity: identity, target: %Worker{identity: identity}, orchestrator: orchestrator}
  end

  test "worker briefing carries the persisted note, progress and host status", ctx do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, note} =
             Aiur.AgentStatusNote.record(
               ctx.identity.identifier,
               "Working through tests",
               %{
                 "doing" => "Run the focused suite",
                 "why" => "Check the status card",
                 "next" => "Review the diff",
                 "waiting_on" => "CI",
                 "asks" => "None",
                 "risks" => "",
                 "pr" => "123",
                 "updated_reason" => "long_step"
               },
               root: ctx.root,
               now: now
             )

    assert {:ok, ^note} = Aiur.AgentStatusNote.latest(ctx.identity.identifier, root: ctx.root)

    assert {:ok, %Briefing{} = briefing} = brief(ctx, delivery_status: fn 9, 1_000 -> {:ok, :consumed} end)
    assert briefing.current_task == %{value: "Run the focused suite", observed_at: now, max_age_s: 600}
    assert briefing.next_steps.value == ["Review the diff"]
    assert briefing.waiting_on.value == "CI"
    assert briefing.questions.value == ["None"]
    assert Enum.any?(briefing.extra, &(&1.title == "Progress" and &1.text == "72% (fresh)"))
    assert Enum.any?(briefing.extra, &(&1.title == "Phase" and &1.text == "work"))
    assert Enum.any?(briefing.extra, &(&1.title == "PR" and &1.text == "123"))
    assert Enum.any?(briefing.extra, &(&1.title == "CI" and &1.text == "passed (as of 3 min ago)"))
    assert Enum.any?(briefing.extra, &(&1.title == "Review" and &1.text == "APPROVED"))
    assert Enum.any?(briefing.extra, &(&1.title == "Listener mode" and &1.text == "async"))
    assert Enum.any?(briefing.extra, &(&1.title == "Last operator message" and &1.text == "Please check the update (consumed)"))
    assert {rendered, _meta} = Briefing.render(briefing, now: DateTime.add(now, 15, :minute))
    assert rendered =~ "Summary: running"
    assert rendered =~ "Ticket: 42: Ticket 42"
    assert rendered =~ "Doing now: Run the focused suite (as of 15 min ago)"
    assert note["observed_at"] == DateTime.to_iso8601(now)
  end

  test "a missing worker note has an explicit fallback", ctx do
    assert {:ok, %Briefing{} = briefing} = brief(ctx)
    assert briefing.current_task.value == "Ticket 42"
    assert briefing.gaps == ["No note from the agent yet."]
  end

  defp brief(ctx, opts \\ []) do
    BriefingSource.brief(ctx.target, Keyword.merge([orchestrator: ctx.orchestrator, status_note_root: ctx.root], opts))
  end

  defp identity do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_42", "number" => 42}, {"org", "repo"}, {"org", "repo"})
    identity
  end

  defp status_row(identity) do
    %{
      tracker_identity: identity,
      state: :running,
      title: "Ticket 42",
      observed_at: DateTime.utc_now(),
      activity_stage: :work,
      progress_percent: 72,
      progress_freshness: :fresh,
      ci_result: %{
        decision: :passed,
        observed_at_ms: System.monotonic_time(:millisecond) - 180_000,
        pr_number: 123,
        review_decision: "APPROVED"
      },
      listener: %{effective: :async},
      pending_operator_messages: [%{id: 9, text: "Please check the update"}]
    }
  end
end

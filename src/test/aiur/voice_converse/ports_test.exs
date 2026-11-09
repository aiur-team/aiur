Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.VoiceConverse.Host.PortsTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.TrackerIdentity
  alias Aiur.VoiceConverse.Host.{BriefingSource, CommandSource, Worker}

  defmodule Snapshot do
    use GenServer
    def start_link(value), do: GenServer.start_link(__MODULE__, value)
    def init(value), do: {:ok, value}
    def handle_call(:snapshot, _from, :exit), do: {:stop, :normal, :exit}
    def handle_call(:snapshot, _from, value), do: {:reply, value, value}
  end

  defmodule History do
    def list_entries(ref, opts) do
      unless Keyword.fetch!(opts, :principal) == :internal, do: raise(ArgumentError)
      send(self(), {:history_read, ref, opts})
      {:ok, %{entries: [%{role: "agent", body: "journal reply"}], complete_from_start: true, prev_cursor: nil}}
    end
  end

  defmodule MissingHistory do
  end

  defmodule FailedHistory do
    def list_entries(_ref, _opts), do: {:error, :unavailable}
  end

  defmodule Live do
    def snapshot(:exact_generation, []), do: %{state: :live, messages: [%{role: "assistant", body: "live reply"}]}
    def snapshot(:missing_generation, []), do: %{state: :unavailable, messages: []}
  end

  defp target(number \\ 42) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_#{number}", "number" => number}, {"org", "repo"}, {"org", "repo"})
    %Worker{identity: identity, live_source: :exact_generation}
  end

  test "open commands select the worker ticket and only answerable statuses", %{dir: dir} do
    store = start_store!(dir)
    ticket = %{identifier: "42", title: "Worker", url: "https://github.com/org/repo/issues/42"}
    assert {:ok, %{decision: open}} = request(store, %{"question" => "Which path?", "blocking" => false}, ticket: ticket)
    assert {:ok, %{decision: deferred}} = request(store, %{"question" => "Later choice?", "blocking" => true}, ticket: ticket)
    assert {:ok, _} = DecisionStore.defer(deferred.decision_id, [actor: %{kind: :operator, id: "dashboard"}], store)
    assert {:ok, %{decision: dismissed}} = request(store, %{"question" => "Old choice?", "blocking" => false}, ticket: ticket)
    assert {:ok, _} = DecisionStore.dismiss(dismissed.decision_id, [actor: %{kind: :operator, id: "dashboard"}], store)
    assert {:ok, _} = request(store, %{"question" => "Other worker?", "blocking" => false})
    assert {:ok, commands} = CommandSource.open(target(), decision_store: store)
    assert MapSet.new(commands, & &1.id) == MapSet.new([open.decision_id, deferred.decision_id])
    assert Enum.find(commands, &(&1.id == open.decision_id)) == %{id: open.decision_id, version: open.version, question: open.question, options: open.options}
  end

  test "unavailable command store does not report no open commands" do
    assert CommandSource.open(target(), decision_store: :absent_voice_commands) == {:error, :unavailable}
  end

  test "orchestrator exit is unavailable" do
    server = start_supervised!({Snapshot, :exit}, restart: :temporary)
    assert BriefingSource.brief(target(), orchestrator: server) == {:error, :unavailable}
  end

  test "failed status leaves liveness unknown" do
    assert BriefingSource.alive?(target(), orchestrator: :absent_voice_orchestrator) == :unknown
  end

  test "status uses the worker identity and retains its observation timestamp" do
    worker = target()
    now = DateTime.utc_now() |> DateTime.add(-90, :second)
    row = %{tracker_identity: worker.identity, title: "Worker task", state: "testing", observed_at: DateTime.to_iso8601(now)}
    other = %{row | tracker_identity: target(43).identity, title: "Other task"}
    server = start_supervised!({Snapshot, %{running: [other, row], retrying: [], idle: []}})
    assert {:ok, briefing} = BriefingSource.brief(worker, orchestrator: server)
    assert briefing.current_task == %{value: "Worker task", observed_at: now, max_age_s: 30}
    assert briefing.summary.value == "testing"
    {text, _} = VoiceConverse.Briefing.render(briefing)
    assert text =~ "Worker task (as of 1 min ago)"
    refute text =~ "Other task"
    assert BriefingSource.alive?(worker, orchestrator: server)
    assert BriefingSource.alive?(target(44), orchestrator: server) == false
    assert BriefingSource.brief(target(44), orchestrator: server) == {:error, :unavailable}
  end

  test "history reads require internal principal and bounded tail options" do
    worker = target()
    assert {:ok, "Conversation source: journal; complete: true.\nagent: journal reply"} = BriefingSource.details(worker, "conversation", history: History, n: 7)
    assert_received {:history_read, ref, opts}
    assert ref.subject == {:worker, worker.identity}
    assert opts == [principal: :internal, tail: true, limit: 7]
  end

  test "without History capability live generation is used and marked incomplete" do
    assert BriefingSource.details(target(), "conversation", history: MissingHistory, live: Live) ==
             {:ok, "Conversation source: live; complete: false.\nassistant: live reply"}
  end

  test "failed history and unavailable live snapshots are not empty conversations" do
    assert BriefingSource.details(target(), "conversation", history: FailedHistory) == {:error, :unavailable}
    assert BriefingSource.details(%{target() | live_source: :missing_generation}, "conversation", history: MissingHistory, live: Live) == {:error, :unavailable}
  end
end

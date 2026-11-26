defmodule Aiur.TestSupport.BuildHome.CommandStore do
  @moduledoc "A real DecisionStore on a temp dir for the build modal's Command card tests."
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Aiur.DecisionStore
  alias Aiur.TestSupport.EndpointStubs

  @spec start!(atom()) :: atom()
  def start!(name) do
    dir = Aiur.TestSupport.tmp_root!("aiur-build-command-card")
    previous = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :decision_state_dir, previous), else: Application.delete_env(:aiur, :decision_state_dir)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    start_supervised!(
      {DecisionStore,
       name: name,
       state_dir: dir,
       dispatcher: fn _decision, _opts -> {:ok, %{status: :accepted}} end,
       dispatch_delay_ms: 60_000,
       retry_delays_ms: [],
       reconcile_delay_ms: 5_000,
       filesystem_sync_fun: fn -> :ok end},
      id: name
    )

    EndpointStubs.put(decision_store: name)
    name
  end

  @doc "Requests the design's retry Command (J:206 `a3`) on `ticket`; `opts` override fields."
  @spec request!(atom(), String.t(), keyword()) :: Aiur.Decision.t()
  def request!(store, ticket, opts \\ []) do
    source_id = Keyword.get(opts, :source_id, "card-#{System.unique_integer([:positive])}")

    request = %{
      "source_id" => source_id,
      "question" => Keyword.get(opts, :question, "Should in-flight retries be restored after a daemon restart, or stay process-local? (#{source_id})"),
      "blocking" => Keyword.get(opts, :blocking, true),
      "urgency" => "critical",
      "reversibility" => "reversible",
      "options" =>
        Keyword.get(opts, :options, [
          %{"id" => "persist", "label" => "Persist to disk, rehydrate on boot", "description" => "Survives a restart"},
          %{"id" => "local", "label" => "Keep process-local"}
        ]),
      "recommendation" => Keyword.get(opts, :recommendation, %{"option_id" => "persist", "reason" => "Restarts are routine"})
    }

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               request,
               [
                 ticket: %{identifier: ticket, title: "Persist retry state across restarts", url: nil},
                 source: %{agent_id: "agent-#{ticket}", session_id: "session-#{ticket}", event_id: "event-#{source_id}"}
               ],
               store
             )

    decision
  end

  @doc "Answers `decision` directly in the store, as the Commands page, CLI or Executor would."
  @spec answer!(atom(), Aiur.Decision.t(), String.t(), map()) :: map()
  def answer!(store, decision, option_id, actor \\ %{kind: :operator, id: "elsewhere"}) do
    payload = %{"idempotency_key" => "elsewhere-#{System.unique_integer([:positive])}", "expected_version" => decision.version, "option_id" => option_id}
    assert {:ok, accepted} = DecisionStore.answer(decision.decision_id, payload, [actor: actor], store)
    accepted
  end
end

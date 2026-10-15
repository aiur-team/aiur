defmodule Aiur.DecisionStoreCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Aiur.{
    AlertFeed,
    Alerts,
    Boot,
    Decision,
    DecisionDispatchTasks,
    DecisionEvent,
    DecisionExpiry,
    DecisionHistory,
    DecisionProjection,
    DecisionPubSub,
    DecisionStore,
    DecisionValidation,
    ExecutorCommandAttention,
    ExecutorCommandCLI,
    Issue,
    Journal
  }

  alias Aiur.Events.{Exchange, IdGenerator}

  # A deadlock backstop, not a race window. The reconciliation report is
  # published unconditionally by the pass that boot always schedules, so the
  # only way to reach this bound is a store that never reconciled at all —
  # which is a failure whatever the number is. Raising or lowering it cannot
  # change a verdict the way the 1_000 ms boot deadline it replaced could.
  @reconcile_report_timeout_ms 30_000

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}

  using do
    quote do
      import ExUnit.CaptureLog
      import Aiur.DecisionStoreCase
      import Aiur.TestSupport, only: [receive_barrier: 1]

      alias Aiur.AgentRunner.EventsDigest

      alias Aiur.{
        AlertFeed,
        Alerts,
        Boot,
        Decision,
        DecisionDispatchTasks,
        DecisionEvent,
        DecisionExpiry,
        DecisionHistory,
        DecisionProjection,
        DecisionPubSub,
        DecisionStore,
        DecisionValidation,
        ExecutorCommandAttention,
        ExecutorCommandCLI,
        Issue,
        Journal
      }

      alias Aiur.DecisionEvent.Unrecognized
      alias Aiur.DecisionStore.RetainedSnapshot
      alias Aiur.Events.{Exchange, IdGenerator}
      alias AiurWeb.ControlCenterPresenter
      alias AiurWeb.OperatorControlCenter.DecisionPresenter

      @reconcile_report_timeout_ms unquote(@reconcile_report_timeout_ms)
      @ticket unquote(Macro.escape(@ticket))
      @source unquote(Macro.escape(@source))
    end
  end

  setup do
    :ok = Aiur.TestSupport.ensure_id_generator_running()
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-store")
    Application.put_env(:aiur, :decision_state_dir, dir)

    on_exit(fn ->
      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  def start_store!(dir, opts \\ []) do
    Application.put_env(:aiur, :decision_state_dir, dir)

    start_opts =
      Keyword.merge([name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end], opts)

    {:ok, pid} = DecisionStore.start_link(start_opts)
    pid
  end

  def request(pid, payload, opts \\ []) do
    DecisionStore.request(payload, Keyword.merge([ticket: @ticket, source: @source], opts), pid)
  end

  def decision_index_key(decision) do
    urgency = %{low: 0, normal: 1, high: 2, critical: 3}

    {
      decision.decision_status in [:expired, :dismissed, :resolved],
      not decision.blocking,
      -Map.fetch!(urgency, decision.urgency),
      -DateTime.to_unix(decision.created_at, :microsecond),
      decision.decision_id
    }
  end

  def project_attention(pid, payload, opts \\ []) do
    DecisionStore.project_attention(
      payload,
      Keyword.merge([ticket: @ticket, source: @source, legacy_attention: legacy_attention()], opts),
      pid
    )
  end

  def enrich_attention(pid, payload, opts) do
    DecisionStore.enrich_attention(
      payload,
      Keyword.merge([ticket: @ticket, source: @source, legacy_attention: legacy_attention()], opts),
      pid
    )
  end

  def legacy_attention do
    %{
      slug: "scope-question",
      topic: "ticket.979.agent.attention.scope-question"
    }
  end

  def minimal_attention(question \\ "Which scope should own this?") do
    %{
      "question" => question,
      "blocking" => true,
      "kind" => "legacy_attention",
      "source_id" => "legacy_attention:scope-question"
    }
  end

  def answer(pid, decision_id, payload, opts \\ []) do
    DecisionStore.answer(
      decision_id,
      payload,
      Keyword.merge([actor: %{kind: :operator, id: "operator-1"}], opts),
      pid
    )
  end

  def dispatch_fence_size({:dispatch_action, fence, false}),
    do: fence |> :erlang.term_to_binary() |> byte_size()

  def enrich(pid, decision_id, patch, expected_version, opts \\ []) do
    DecisionStore.enrich(
      decision_id,
      patch,
      Keyword.merge(
        [
          actor: %{kind: :supervisor, id: "supervising-agent"},
          expected_version: expected_version,
          now: ~U[2026-07-12 11:00:00Z]
        ],
        opts
      ),
      pid
    )
  end

  def answerable_request(source_id) do
    %{
      "question" => "Deploy now?",
      "blocking" => true,
      "source_id" => source_id,
      "options" => [%{"id" => "ship", "label" => "Ship it"}]
    }
  end

  def supervisor_basis(confidence) do
    %{
      confidence: confidence,
      alternatives_considered: ["Wait"],
      reversibility_belief: :reversible,
      policy_basis: %{
        authority: :supervisor_allowed,
        kind: "architecture",
        reversibility: :reversible,
        checks: %{authority_delegable: true, kind_allowed: true, reversibility_allowed: true},
        allow_non_reversible: false
      }
    }
  end

  def audit_type(%DecisionEvent{type: type}), do: type

  def audit_type(%Aiur.Decision{}), do: :requested

  def correlated_queue_item(decision, action, attempt_id, queue_item_id) do
    %{
      id: queue_item_id,
      target_issue_identifier: decision.ticket.identifier,
      action_id: action.action_id,
      correlation: %{
        decision_id: decision.decision_id,
        decision_version: action.decision_version,
        action_id: action.action_id,
        attempt_id: attempt_id,
        actor: Map.get(action, :actor) || action |> Map.get(:answer, %{}) |> Map.get(:actor)
      }
    }
  end

  def wait_for_decision(pid, decision_id, predicate, attempts \\ 100)

  def wait_for_decision(_pid, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  def wait_for_decision(pid, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, pid)

    if predicate.(decision) do
      decision
    else
      Process.sleep(10)
      wait_for_decision(pid, decision_id, predicate, attempts - 1)
    end
  end

  def wait_for_dispatch_count(pid, expected, attempts \\ 100)

  def wait_for_dispatch_count(_pid, _expected, 0), do: flunk("dispatch count did not reach expected value")

  def wait_for_dispatch_count(pid, expected, attempts) do
    if map_size(:sys.get_state(pid).dispatching) == expected do
      :ok
    else
      Process.sleep(10)
      wait_for_dispatch_count(pid, expected, attempts - 1)
    end
  end

  def wait_for_feed_empty(log_root, topic, attempts \\ 200)

  def wait_for_feed_empty(_log_root, _topic, 0),
    do: flunk("needs-attention feed did not empty after listener restart")

  def wait_for_feed_empty(log_root, topic, attempts) do
    if case_attention_alerts(log_root, topic) == [] do
      :ok
    else
      Process.sleep(10)
      wait_for_feed_empty(log_root, topic, attempts - 1)
    end
  end

  def wait_for_named_process(name, previous, attempts \\ 100)

  def wait_for_named_process(_name, _previous, 0), do: flunk("named process did not restart")

  def wait_for_named_process(name, previous, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_named_process(name, previous, attempts - 1)
    end
  end

  def unique_coordinator_name(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end

  # A non-executor-answerable Command (human_required, no options) in the
  # already-expired state, the shape whose `decision-expired-unanswerable`
  # alert was the historical backlog #2458 retires.
  def expired_unanswerable_decision(now) do
    {:ok, decision} =
      DecisionValidation.normalize(
        %{
          "question" => "Which archival target?",
          "blocking" => false,
          "authority" => "human_required",
          "source_id" => "expired-unanswerable-1"
        },
        ticket: %{@ticket | identifier: "979"},
        source: @source,
        now: DateTime.add(now, -3_600, :second)
      )

    %{decision | decision_status: :expired}
  end

  # Mirrors `Aiur.DecisionAttentionSignals.attention_topic/2` for the expired
  # signal, so a test can seed and then read the exact topic the reconcile
  # retires.
  def expired_unanswerable_topic(decision) do
    digest =
      :sha256
      |> :crypto.hash(decision.decision_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "ticket.#{decision.ticket.identifier}.agent.attention.decision-expired-unanswerable-#{digest}"
  end

  # #2343: each case's own store writes its delivery attention into the
  # case-scoped `log_root` via the shared `:log_file` app env, but any other
  # emitter alive during the case body resolves that same global env, so the
  # root can transiently carry sibling alerts (observed: `decision-expired-
  # unanswerable` from other tickets). These cases assert on their OWN alert,
  # so the read is scoped to the case's topic rather than assuming the root is
  # globally empty — the root being "owned" by one case is not something a test
  # can rely on while the log root is a VM-global knob.
  def case_attention_alerts(log_root, topic) do
    AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)
    |> Enum.filter(&(&1["topic"] == topic))
  end
end

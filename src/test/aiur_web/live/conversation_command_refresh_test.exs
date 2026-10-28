Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ConversationCommandRefreshTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{AnchorResolver, History, Ingest, Ref, Store, TestSupport}
  alias Aiur.{DecisionStore, TrackerIdentity}
  alias AiurWeb.Endpoint

  setup context do
    ctx = TestSupport.setup(context)
    Application.put_env(:aiur, :conversation_journal, Keyword.put(Application.fetch_env!(:aiur, :conversation_journal), :store, Store))
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_refresh", "number" => 6636}, {"aiur-team", "aiur"}, {"aiur-team", "aiur"})
    {:ok, ref} = Ref.worker(identity)
    secret = "ghp_" <> String.duplicate("a", 36)
    Ingest.append(ref, %{source() | role: :worker}, [%{event(1) | body: secret}, %{event(2) | body: secret}, event(3)])
    assert :ok = flush(ref)
    store = start_supervised!({DecisionStore, name: nil, state_dir: Path.join(ctx.root, "commands"), filesystem_sync_fun: fn -> :ok end})
    endpoint = Application.fetch_env!(:aiur, Endpoint)
    updated = Keyword.merge(endpoint, decision_store: store, dashboard_writable: true)
    Application.put_env(:aiur, Endpoint, updated)
    Endpoint.config_change([{Endpoint, updated}], [])
    on_exit(fn -> Application.put_env(:aiur, Endpoint, endpoint) end)
    Map.merge(ctx, %{ref: ref, store: store, secret: secret})
  end

  defp request(ctx, ticket \\ "6636") do
    nonce = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    payload = %{
      "source_id" => "refresh-#{ticket}-#{nonce}",
      "question" => "Proceed?",
      "blocking" => false,
      "authority" => "human_required",
      "reversibility" => "reversible",
      "options" => [%{"id" => "yes", "label" => "Yes", "description" => "Proceed"}]
    }

    assert {:ok, %{decision: row}} =
             Aiur.DecisionStoreCase.request(ctx.store, payload, ticket: %{identifier: ticket, title: "Refresh", url: nil}, source: %{agent_id: "worker", session_id: "session-one", event_id: nil})

    row
  end

  defp anchor(ctx, row, pos, precision) do
    Ingest.anchor(ctx.ref, %{
      "v" => 1,
      "anchor_id" => "#{row.decision_id}-#{precision}",
      "conversation_id" => Ref.conversation_id(ctx.ref),
      "kind" => "command_requested",
      "precision" => precision,
      "pos" => pos,
      "event" => %{"event_id" => 1},
      "subject_ref" => %{"decision_id" => row.decision_id}
    })

    assert :ok = flush(ctx.ref)
    AnchorResolver.stats()
    assert {:ok, %{pos: ^pos}} = History.command_anchor(row.decision_id)
  end

  defp open(ctx) do
    conn = Plug.Conn.put_private(build_conn(), :live_view_connect_info, %{peer_data: %{address: {127, 0, 0, 1}}})
    live(conn, "/conversations/" <> Ref.conversation_id(ctx.ref))
  end

  defp reveal(view), do: render_click(element(view, "#entry-1 button", "Show raw"))

  defp reads(view, fun) do
    :erlang.trace_pattern({History, :list_entries, 2}, true, [:local])
    :erlang.trace(view.pid, true, [:call])

    try do
      fun.()
      :sys.get_state(view.pid)
      ref = :erlang.trace_delivered(view.pid)
      collect_reads(view.pid, ref, [])
    after
      :erlang.trace(view.pid, false, [:call])
      :erlang.trace_pattern({History, :list_entries, 2}, false, [:local])
    end
  end

  defp collect_reads(pid, ref, found) do
    receive do
      {:trace, ^pid, :call, {History, :list_entries, [_id, opts]}} -> collect_reads(pid, ref, [opts | found])
      {:trace_delivered, ^pid, ^ref} -> Enum.reverse(found)
    after
      5_000 -> flunk("entry-read trace was not delivered")
    end
  end

  test "raw reveal survives age ticks and unrelated Commands without reading entries", ctx do
    row = request(ctx)
    anchor(ctx, row, 1, "exact")
    other = request(ctx, "99")
    {:ok, view, _} = open(ctx)
    reveal(view)
    assert has_element?(view, "#entry-1", ctx.secret)

    assert reads(view, fn ->
             send(view.pid, :age_tick)
             render(view)
             send(view.pid, {:decision_changed, other.decision_id, other.version})
             render(view)
           end) == []

    assert has_element?(view, "#entry-1", ctx.secret)
    refute has_element?(view, "#entry-2", ctx.secret)
  end

  test "a changed card rereads only its anchor and honors reveal permission", ctx do
    row = request(ctx)
    anchor(ctx, row, 1, "exact")
    {:ok, view, _} = open(ctx)
    reveal(view)

    assert [options] =
             reads(view, fn ->
               render_change(element(view, "#decision-answer-form-#{row.decision_id}"), %{"decision_id" => row.decision_id, "answer" => %{"choice" => "option:yes"}})
             end)

    assert Keyword.take(options, [:around, :limit, :reveal]) == [around: 1, limit: 1, reveal: true]
    assert has_element?(view, "#entry-1", ctx.secret)
    refute has_element?(view, "#entry-2", ctx.secret)

    Phoenix.Config.put(Endpoint, :dashboard_writable, false)

    options =
      reads(view, fn ->
        assert {:ok, _} =
                 DecisionStore.answer(row.decision_id, %{"option_id" => "yes", "idempotency_key" => "remote", "expected_version" => row.version}, [actor: %{kind: :operator, id: "other"}], ctx.store)

        render(view)
      end)

    assert options != []
    assert Enum.all?(options, &(Keyword.take(&1, [:around, :limit, :reveal]) == [around: 1, limit: 1, reveal: false]))
    refute has_element?(view, "#entry-1", ctx.secret)
  end

  test "an anchor upgrade refreshes old and new positions and retains raw text", ctx do
    row = request(ctx)
    anchor(ctx, row, 1, "observed")
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#entry-1 #conversation-command-#{row.decision_id}")
    reveal(view)

    options =
      reads(view, fn ->
        anchor(ctx, row, 2, "exact")
        render(view)
      end)

    assert Enum.map(options, &Keyword.take(&1, [:around, :limit, :reveal])) |> Enum.sort() == [
             [around: 1, limit: 1, reveal: true],
             [around: 2, limit: 1, reveal: false]
           ]

    refute has_element?(view, "#entry-1 #conversation-command-#{row.decision_id}")
    assert has_element?(view, "#entry-2 #conversation-command-#{row.decision_id}")
    assert has_element?(view, "#entry-1", ctx.secret)
    refute has_element?(view, "#entry-2", ctx.secret)
  end
end

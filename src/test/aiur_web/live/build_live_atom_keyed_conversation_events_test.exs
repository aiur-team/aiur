defmodule AiurWeb.BuildLiveAtomKeyedConversationEventsTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase

  alias Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TestSupport.LiveViewAsync
  alias Aiur.TrackerIdentity

  defmodule Source do
    alias AiurWeb.Build.ConversationSource.Wave0bEvents

    def prepare(ref, _opts), do: {:ok, Map.merge(ref, %{handle: nil, path: nil, running: nil})}

    def tail(ref, _cursor, opts),
      do:
        {:ok,
         %{
           state: :live,
           entries: [%{id: "t:" <> ref.id, k: "say", at: 1_791_407_600_000, text: "hi"}],
           before: "t:0",
           last: "t:0",
           more?: Agent.get(opts[:control], &Map.get(&1, :more?, true)),
           live?: true,
           observed_at: nil
         }}

    def page(_ref, _cursor, _opts), do: {:ok, %{entries: [], before: nil, more?: false}}
    def subscribe(_ref, _opts), do: :ok
    def unsubscribe(_ref, _opts), do: :ok
    def events_subscribe(identity, _opts), do: Wave0bEvents.subscribe(identity)
    def events_unsubscribe(topic, _opts), do: Wave0bEvents.unsubscribe(topic)

    def events(ref, opts),
      do: {:ok, Agent.get(opts[:control], &Map.put(&1, :identity, identity(ref.id)))}

    def identity(id),
      do: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "owner",
        repository: "repo",
        provider_id: "I-" <> id,
        identifier: id,
        reason: nil
      }
  end

  defmodule AtomTicketSource do
    @moduledoc false
    @behaviour AiurWeb.Build.DataSource
    alias Aiur.TestSupport.BuildHome.ProtocolCase

    @impl true
    def ticket(id, opts) do
      with {:ok, row} <- ProtocolCase.Spy.ticket(id, opts) do
        overrides = Keyword.get(opts, :atom_row_overrides, %{})
        {:ok, row |> atomize_keys() |> Map.merge(Map.get(overrides, id, %{}))}
      end
    end

    @impl true
    def snapshot(opts), do: ProtocolCase.Spy.snapshot(opts)

    @impl true
    def subscribe(opts), do: ProtocolCase.Spy.subscribe(opts)

    @impl true
    def earlier(before, zone, opts), do: ProtocolCase.Spy.earlier(before, zone, opts)

    defp atomize_keys(map) when is_map(map),
      do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), atomize_keys(value)} end)

    defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
    defp atomize_keys(value), do: value
  end

  setup do
    previous = Application.get_env(:aiur, :build_conversation_source)

    control =
      start_supervised!({
        Agent,
        fn ->
          %{
            log: {:ok, []},
            history: {:error, :none},
            merges: [],
            decisions: {:ok, []},
            pause: nil,
            repository: nil,
            read_at: 0
          }
        end
      })

    Application.put_env(:aiur, :build_conversation_source, {Source, [control: control]})

    EndpointStubs.scope(build_events_timer: fn _pid, _message, _ms -> make_ref() end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :build_conversation_source, previous),
        else: Application.delete_env(:aiur, :build_conversation_source)
    end)

    %{control: control}
  end

  test "atom-keyed live rows show their dependency and PR without an orphan merge", %{
    control: control
  } do
    [ticket, dependency | _] = rows()
    id = ticket["id"]
    dependency_id = dependency["id"]

    overrides = %{
      id => %{
        deps: [dependency_id],
        dep_states: %{dependency_id => "unknown"},
        pr: %{num: 88, state: "open"}
      }
    }

    Application.put_env(
      :aiur,
      :build_data_source,
      {AtomTicketSource, [test_pid: self(), dataset: "live", atom_row_overrides: overrides]}
    )

    orphan_merge = %{
      ticket_id: nil,
      repository: "owner/repo",
      number: 7193,
      merged_at: ~U[2026-10-07 21:13:20Z]
    }

    Agent.update(control, &%{&1 | merges: [orphan_merge], repository: "owner/repo"})
    Agent.update(control, &Map.put(&1, :more?, false))

    assert %{"kind" => "conversation", "entries" => entries} = open(view(), id)
    ids = for %{"k" => "ev", "id" => event_id} <- entries, do: event_id

    assert "ev:dep:#{dependency_id}" in ids
    assert "ev:pr:88" in ids
    refute Enum.any?(entries, &(&1["label"] == "Merged PR #7193"))
  end

  defp view do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    view
  end

  defp rows,
    do:
      Enum.filter(
        data()["sections"]["hist"] ++ data()["sections"]["now"],
        &(&1["agent"] != nil and &1["start"] != nil)
      )

  defp open(view, id) do
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, reply)
    reply
  end
end

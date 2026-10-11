defmodule AiurWeb.BuildOrderLiveCase do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.{AgentPubSub, TrackerIdentity}
  alias Aiur.TestSupport.{AwaitingCommands, LiveViewAsync}

  alias Aiur.BuildOrder.AdHocSource.Snapshot, as: AdHocSnapshot
  alias Aiur.BuildOrder.{Catalog, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.TicketDetail.Snapshot, as: DetailSnapshot
  alias AiurWeb.Endpoint

  defmacro __using__(_opts) do
    quote do
      use Aiur.TestSupport

      import AiurWeb.BuildOrderLiveCase
      import Phoenix.ConnTest, except: [build_conn: 0]
      import Phoenix.LiveViewTest

      alias Aiur.{AgentPubSub, TrackerIdentity}
      alias Aiur.TestSupport.{AwaitingCommands, LiveViewAsync}

      alias Aiur.BuildOrder.AdHocSource.Snapshot, as: AdHocSnapshot
      alias Aiur.BuildOrder.{Catalog, Lifecycle, Member, ProviderHealth, RootSummary, SelectedRoot}
      alias Aiur.BuildOrder.GraphProjection.Snapshot
      alias Aiur.BuildOrder.TicketDetail.Snapshot, as: DetailSnapshot
      alias Aiur.BuildOrder.TicketDetail.State
      alias Aiur.BuildOrder.TicketHistory
      alias AiurWeb.BuildOrder.Runtime
      alias AiurWeb.BuildOrderLiveCase.FakeDataSource
      alias AiurWeb.Endpoint

      @endpoint Endpoint

      setup {AiurWeb.BuildOrderLiveCase, :setup_source}
    end
  end

  defmodule FakeDataSource do
    @moduledoc false
    use GenServer

    alias Aiur.BuildOrder.GraphProjection.Snapshot

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def calls(server), do: GenServer.call(server, :calls)
    def put_catalog(server, catalog), do: GenServer.call(server, {:put_catalog, catalog})
    def put_selected(server, selected), do: GenServer.call(server, {:put_selected, selected})

    def subscribe_catalog(server), do: invoke(server, :subscribe_catalog, [])

    def unsubscribe_catalog(server, repository),
      do: invoke(server, :unsubscribe_catalog, [repository])

    def catalog(server), do: invoke(server, :catalog, [])

    def subscribe_sources(server) do
      :ok = Aiur.AgentPubSub.subscribe_running()
      invoke(server, :subscribe_sources, [])
    end

    def load_sources(server) do
      loader = invoke(server, :load_sources, [])
      loader.()
    end

    def subscribe_selected(server, identity), do: invoke(server, :subscribe_selected, [identity])

    def unsubscribe_selected(server, identity),
      do: invoke(server, :unsubscribe_selected, [identity])

    def selected(server, identity), do: invoke(server, :selected, [identity])
    def demand(server, identity), do: invoke(server, :demand, [identity])
    def refresh(server, identity), do: invoke(server, :refresh, [identity])
    def refresh_catalog(server), do: invoke(server, :refresh_catalog, [])
    def release(server, identity), do: invoke(server, :release, [identity])
    def subscribe_context(server, identity), do: invoke(server, :subscribe_context, [identity])

    def unsubscribe_context(server, identity),
      do: invoke(server, :unsubscribe_context, [identity])

    def load_context(server, identity) do
      loader = invoke(server, :load_context, [identity])
      loader.(identity)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         report: Keyword.fetch!(opts, :report),
         catalog: Keyword.fetch!(opts, :catalog),
         selected: Map.new(Keyword.get(opts, :selected, []), &{&1.scope, &1}),
         sources:
           Keyword.get(opts, :sources, %{
             execution: %{running: [], retrying: [], idle: []},
             activity: %{generation: 1, entries: []}
           }),
         sources_loader:
           Keyword.get(opts, :sources_loader, fn ->
             Keyword.get(opts, :sources, %{
               execution: %{running: [], retrying: [], idle: []},
               activity: %{generation: 1, entries: []}
             })
           end),
         context_loader:
           Keyword.get(opts, :context_loader, fn _identity ->
             %{detail: {:error, :unavailable}, history: {:error, :unavailable}}
           end),
         calls: []
       }}
    end

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:put_catalog, catalog}, _from, state),
      do: {:reply, :ok, %{state | catalog: catalog}}

    def handle_call({:put_selected, %Snapshot{scope: scope} = selected}, _from, state),
      do: {:reply, :ok, %{state | selected: Map.put(state.selected, scope, selected)}}

    def handle_call({:invoke, name, args}, _from, state) do
      call = {name, args}
      send(state.report, {:build_order_source_call, call})
      {:reply, reply(name, args, state), %{state | calls: [call | state.calls]}}
    end

    defp invoke(server, name, args), do: GenServer.call(server, {:invoke, name, args})
    defp reply(:subscribe_catalog, [], _state), do: :ok
    defp reply(:unsubscribe_catalog, [_repository], _state), do: :ok
    defp reply(:catalog, [], state), do: state.catalog
    defp reply(:subscribe_sources, [], _state), do: :ok
    defp reply(:load_sources, [], state), do: state.sources_loader
    defp reply(:subscribe_selected, [_identity], _state), do: :ok
    defp reply(:unsubscribe_selected, [_identity], _state), do: :ok
    defp reply(:selected, [identity], state), do: selected_reply(state, identity)
    defp reply(:demand, [identity], state), do: selected_reply(state, identity)
    defp reply(:refresh, [_identity], _state), do: :ok
    defp reply(:refresh_catalog, [], _state), do: :ok
    defp reply(:release, [_identity], _state), do: :ok
    defp reply(:subscribe_context, [_identity], _state), do: :ok
    defp reply(:unsubscribe_context, [_identity], _state), do: :ok
    defp reply(:load_context, [_identity], state), do: state.context_loader

    defp selected_reply(state, identity) do
      case Map.fetch(state.selected, {:selected, identity}) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> {:error, :unavailable}
      end
    end
  end

  def setup_source(context) do
    first = identity(42, "NODE-42")
    second = identity(43, "NODE-43")

    catalog =
      catalog_snapshot(
        [root(first, "Root forty-two"), root(second, "Root forty-three")],
        1,
        :healthy
      )

    source =
      start_supervised!(
        {FakeDataSource,
         report: self(),
         catalog: catalog,
         selected: [
           selected_snapshot(first, "Root forty-two", 1, :healthy),
           selected_snapshot(second, "Root forty-three", 1, :healthy)
         ]}
      )

    previous_source = Application.get_env(:aiur, :build_order_data_source)
    previous_clock = Application.get_env(:aiur, :build_order_display_clock)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, :build_order_data_source, {FakeDataSource, source})

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false
      )
      |> Keyword.merge(awaiting_commands_config(context))

    Application.put_env(:aiur, Endpoint, endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      restore_application_env(:build_order_data_source, previous_source)
      restore_application_env(:build_order_display_clock, previous_clock)
      restore_application_env(Endpoint, previous_endpoint)
    end)

    %{source: source, first: first, second: second}
  end

  def call_index(calls, expected) do
    Enum.find_index(calls, &(&1 == expected)) ||
      flunk("missing source call #{inspect(expected)} in #{inspect(calls)}")
  end

  def catalog_snapshot(
        entries,
        generation,
        state,
        snapshot_repository \\ repository(),
        authority_epoch \\ 1
      ) do
    data = if is_list(entries), do: Catalog.new(entries, health(generation, state))

    %Snapshot{
      scope: :catalog,
      repository: snapshot_repository,
      authority_epoch: authority_epoch,
      generation: generation,
      data: data,
      health: health(generation, state)
    }
  end

  def selected_snapshot(identity, title_or_data, generation, state, opts \\ [])

  def selected_snapshot(identity, %SelectedRoot{} = data, generation, state, opts) do
    %Snapshot{
      scope: {:selected, identity},
      repository: Keyword.get(opts, :repository, repository()),
      authority_epoch: Keyword.get(opts, :authority_epoch, 1),
      generation: generation,
      data: data,
      health: health(generation, state, opts)
    }
  end

  def selected_snapshot(identity, title, generation, state, opts) do
    data =
      if is_binary(title),
        do:
          SelectedRoot.new(
            root(identity, title),
            Keyword.get(opts, :members, []),
            health(generation, state)
          ),
        else: nil

    %Snapshot{
      scope: {:selected, identity},
      repository: Keyword.get(opts, :repository, repository()),
      authority_epoch: Keyword.get(opts, :authority_epoch, 1),
      generation: generation,
      data: data,
      health: health(generation, state, opts)
    }
  end

  def root(identity, title) do
    RootSummary.new(%{
      identity: identity,
      title: title,
      url: "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  def member(number) do
    identity = identity(number, "NODE-#{number}")

    Member.new(%{
      identity: identity,
      title: "Ticket #{number}",
      url: "https://github.com/owner/repo/issues/#{number}",
      state: "OPEN",
      state_reason: nil,
      labels: ["phase:1", "build-lane:dashboard-ui"]
    })
  end

  def breakdown_member(number, opts) do
    identity = identity(number, "NODE-#{number}")

    labels = [
      "complexity:#{Keyword.fetch!(opts, :complexity)}",
      "phase:#{Keyword.fetch!(opts, :phase)}",
      "build-lane:#{Keyword.fetch!(opts, :lane)}"
    ]

    Member.new(%{
      identity: identity,
      title: "Ticket #{number}",
      url: "https://github.com/owner/repo/issues/#{number}",
      state: "OPEN",
      state_reason: nil,
      labels: labels
    })
  end

  def sources_for_member(identity, work_state, pause_reason, progress) do
    observed_at = ~U[2026-08-01 12:00:00Z]

    %{
      execution: %{
        running: [
          %{
            tracker_identity: identity,
            work_state: work_state,
            pause_reason: pause_reason,
            tracker_paused: work_state == :paused,
            waiting_reason: :active,
            started_at: observed_at
          }
        ],
        retrying: [],
        idle: []
      },
      activity: %{
        generation: progress,
        entries: [
          %{
            identity: identity,
            status: :fresh,
            active_stage: :work,
            stage: %{
              status: :known,
              value: :work,
              freshness: :fresh,
              observed_at: observed_at,
              event_id: progress
            },
            progress: %{
              status: :known,
              percent: progress,
              source: :checkin,
              freshness: :fresh,
              occurred_at: observed_at,
              observed_at: observed_at,
              event_id: progress
            },
            observed_at: observed_at,
            retention: :current
          }
        ]
      },
      adhoc: nil
    }
  end

  def health(generation, state, opts \\ []) do
    ProviderHealth.new(generation, state, state == :healthy, opts)
  end

  def identity(number, provider_id, identity_repository \\ repository()) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "database_id" => number, "number" => number},
        identity_repository,
        identity_repository
      )

    identity
  end

  def repository, do: {"owner", "repo"}

  def install_source(opts) do
    source =
      start_supervised!(
        Supervisor.child_spec(
          {FakeDataSource,
           [
             report: self(),
             catalog: Keyword.get(opts, :catalog),
             selected: Keyword.get(opts, :selected, []),
             sources_loader:
               Keyword.get(opts, :sources_loader, fn ->
                 %{
                   execution: %{running: [], retrying: [], idle: []},
                   activity: %{generation: 1, entries: []}
                 }
               end),
             context_loader:
               Keyword.get(opts, :context_loader, fn _identity ->
                 %{detail: {:error, :unavailable}, history: {:error, :unavailable}}
               end)
           ]},
          id: make_ref()
        )
      )

    Application.put_env(:aiur, :build_order_data_source, {FakeDataSource, source})
    source
  end

  def restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  def route_title(document) do
    document |> Floki.find("#route-title") |> Floki.text() |> String.trim()
  end

  def selected_lede(document) do
    case Floki.find(document, ".bo-selected-summary > p.bo-selected-lede") do
      [] -> nil
      found -> found |> Floki.text() |> String.trim()
    end
  end

  # Dashboard routes are behind the FinancialDataAccess plug, which challenges
  # any request once credentials are configured (regardless of `dashboard_auth_required`).
  # test_helper configures credentials globally, so every Build Order render test must
  # present them.
  def build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
  end

  # --- awaiting-Commands banner ---------------------------------------------

  def awaiting_commands_config(context) do
    case context[:awaiting_commands] do
      nil -> []
      counts -> [decision_store: AwaitingCommands.start(counts)]
    end
  end
end

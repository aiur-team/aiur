Code.require_file("streamdeck_fleet_fixture.ex", __DIR__)

defmodule AiurWeb.StreamdeckChannelCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  import Phoenix.ChannelTest

  alias Aiur.{AgentEvents, DecisionValidation, IssueLog, StreamdeckFleetFixture}
  alias AiurWeb.{Endpoint, StreamdeckAuth, StreamdeckSocket}

  @endpoint Endpoint

  using do
    quote do
      import Phoenix.ChannelTest
      import Aiur.TestSupport, only: [receive_barrier: 1]

      import Plug.Conn, only: [put_req_header: 3]
      import Plug.Test
      import AiurWeb.StreamdeckChannelCase

      alias Aiur.{AgentEvents, DecisionValidation, IssueLog, StreamdeckFleetFixture}
      alias Aiur.AgentPubSub
      alias Aiur.DecisionQuery.Cursor
      alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents
      alias Aiur.ProviderMeterSnapshot
      alias AiurWeb.{Endpoint, FinancialDataAccess, StreamdeckAuth, StreamdeckChannel, StreamdeckProjection, StreamdeckSocket}
      alias AiurWeb.StreamdeckChannelCase.FakeDecisionStore
      alias Phoenix.Socket.Message
      alias Phoenix.Socket.V2.JSONSerializer

      @endpoint Endpoint

      setup do
        AiurWeb.StreamdeckChannelCase.setup_channel()
      end
    end
  end

  # A decision store that returns one fixed Command regardless of the query, and
  # reports every `answer` call with its opts so the channel test can assert the
  # actor the wire recorded. The Decision struct is built through the real
  # validation path so `StreamdeckCommands.item/1` projects it as production
  # would.
  defmodule FakeDecisionStore do
    @moduledoc false
    use GenServer

    def start_link(decision, report), do: GenServer.start_link(__MODULE__, {decision, report})

    @impl true
    def init({decision, report}), do: {:ok, %{decision: decision, report: report}}

    @impl true
    def handle_call({:retained_query, _query}, _from, %{decision: decision} = state) do
      send(state.report, {:fake_decision_query, :hit})

      {:reply,
       {:ok,
        %{
          decisions: [decision],
          has_next?: false,
          next_key: nil,
          total: 1,
          partial?: false,
          partial_reason: nil,
          counts: %{open: 1, blocking: 1, total: 1},
          health: :writable
        }}, state}
    end

    def handle_call({:retained_lookup, decision_id}, _from, %{decision: decision} = state) do
      found = if decision_id == decision.decision_id, do: decision
      send(state.report, {:fake_decision_lookup, decision_id})
      {:reply, {:ok, %{decision: found, health: :writable}}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, %{decision: decision} = state) do
      send(state.report, {:fake_decision_answer, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted, decision: decision}}, state}
    end

    def handle_call(_request, _from, state), do: {:reply, {:error, :store_unavailable}, state}
  end

  def command_decision(ticket_identifier) do
    payload = %{
      "source_id" => "streamdeck-command",
      "question" => "Ship the change?",
      "blocking" => true,
      "authority" => "human_required",
      "reversibility" => "reversible",
      "options" => [%{"id" => "ship", "label" => "Ship it", "description" => "Merge and deploy now."}]
    }

    {:ok, decision} =
      DecisionValidation.normalize(payload,
        ticket: %{identifier: ticket_identifier},
        source: %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-1"}
      )

    decision
  end

  def setup_channel do
    original_config = Application.get_env(:aiur, Endpoint, [])
    original_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    original_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    # The voice session fake runs inside the channel, not the test process, so
    # it reaches this test through a registered name rather than a closure.
    Process.register(self(), :streamdeck_channel_test_observer)

    config =
      original_config
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: false,
        streamdeck_snapshot_fun: fn -> snapshot() end,
        streamdeck_fleet_subscribe_fun: StreamdeckFleetFixture.subscription(),
        streamdeck_provider_meters_fun: fn -> %{codex: %{state: :observed}, claude: %{state: :unknown}} end,
        streamdeck_decisions_fun: fn -> %{count: 2} end,
        streamdeck_transcript_flush_ms: 20
      )

    Application.put_env(:aiur, Endpoint, config)

    Aiur.TestSupport.start_owned_endpoint!()
    Endpoint.config_change([{Endpoint, config}], [])

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, original_config)
      restore_env("AIUR_DASHBOARD_USERNAME", original_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", original_password)
    end)

    :ok
  end

  def put_endpoint_config(extra) do
    previous = Application.get_env(:aiur, Endpoint, [])
    config = Keyword.merge(previous, extra)

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, previous)
      # The supervised endpoint may already be down when this runs; its config
      # cache dies with it, so there is nothing left to restore.
      if Process.whereis(Endpoint), do: Endpoint.config_change([{Endpoint, previous}], [])
    end)

    Application.put_env(:aiur, Endpoint, config)
    :ok = Endpoint.config_change([{Endpoint, config}], [])
    :ok
  end

  def joined_socket do
    socket = authenticated_socket()
    {:ok, _reply, socket} = subscribe_and_join(socket, "streamdeck:fleet")
    assert_push("snapshot", _payload)
    socket
  end

  def authenticated_socket do
    assert {:ok, token} = StreamdeckAuth.issue_token()
    assert {:ok, socket} = StreamdeckSocket.connect(%{"token" => token}, socket(StreamdeckSocket, "authenticated", %{}), %{})
    socket
  end

  def snapshot do
    %{agents: [AgentEvents.agent_summary("AIUR-1", :running, 0, %{title: "Channel tests"})]}
  end

  def write_transcript(prefix, body, turn_id) do
    identifier = "#{prefix}-#{System.unique_integer([:positive])}"
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      Jason.encode!(%{
        "role" => "assistant",
        "body" => body,
        "timestamp" => "2026-07-30T00:00:00Z",
        "msg_id" => "#{turn_id}-message",
        "sequence" => 1,
        "turn_id" => turn_id,
        "payload" => nil
      }) <> "\n"
    )

    identifier
  end

  # The shared event bus is a second, separate source from the transcript, so a
  # fixture that wants real event keys has to write real `[event:<kind>]` rows.
  def write_event_log(identifier, lines) do
    path = IssueLog.event_log_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm(path) end)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  def event_line(id, kind, topic, summary, timestamp) do
    "#{timestamp} [event:#{kind}] id=#{id} #{topic}: #{summary}"
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)
end

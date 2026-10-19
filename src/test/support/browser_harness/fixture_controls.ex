defmodule Aiur.BrowserHarness.FixtureBuildDataset do
  @moduledoc false

  use Phoenix.Controller, formats: []

  alias Aiur.TestSupport.BuildHome.FixtureSource

  def configure(conn, %{"dataset" => dataset}) do
    if dataset in FixtureSource.datasets() do
      Application.put_env(:aiur, :build_fixture_dataset, dataset)
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      redirect(conn, to: "/build" <> query)
    else
      conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(404, "unknown build fixture dataset")
    end
  end
end

defmodule Aiur.BrowserHarness.FixtureStreamdeckControl do
  @moduledoc """
  Lets one browser spec opt its own fixture server into a writable dashboard.

  Stream Deck key presses only reach the agent control facade when the
  dashboard is writable, so the operator-flow spec needs that gate open to
  prove a pause actually pauses. Every `run-browser-tests.mjs` invocation gets
  its own fixture server, so flipping it here cannot leak into another spec.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Aiur.BrowserHarness.FixtureServer

  @modes %{"writable" => true, "read_only" => false}

  def configure(conn, %{"mode" => mode}) when is_map_key(@modes, mode) do
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, Map.fetch!(@modes, mode))
    FixtureServer.reset_streamdeck_pauses()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "streamdeck fixture control: #{mode}")
  end

  def configure(conn, _params), do: send_resp(conn, 404, "unknown streamdeck fixture control mode")
end

defmodule Aiur.BrowserHarness.CommandAnswerFixture do
  @moduledoc false
  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Aiur.DecisionStore
  alias Aiur.Events.IdGenerator

  @store __MODULE__.Store

  def configure(conn, _params) do
    decision = seed_decision!()
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, true)
    :persistent_term.put({__MODULE__, :join_delay_ms}, 4_000)
    :persistent_term.put({__MODULE__, :join_state}, :waiting)
    redirect(conn, to: "/commands/#{decision.decision_id}")
  end

  def join_status(conn, _params) do
    json(conn, %{state: to_string(:persistent_term.get({__MODULE__, :join_state}, :waiting))})
  end

  def status(conn, _params) do
    case DecisionStore.get(:persistent_term.get({__MODULE__, :decision_id}), @store) do
      {:ok, decision} ->
        json(conn, %{
          decision_status: to_string(decision.decision_status),
          selected_option_id: decision.answer && decision.answer.selected_option_id,
          actor: decision.answer && %{kind: to_string(decision.answer.actor.kind), id: decision.answer.actor.id}
        })

      _ ->
        send_resp(conn, 404, "Command fixture missing")
    end
  end

  def current(decision_id) do
    case :persistent_term.get({__MODULE__, :decision_id}, nil) do
      ^decision_id -> DecisionStore.get(decision_id, @store)
      _ -> :error
    end
  end

  # Only the seeded decision's URL mounts the real dashboard; other specs share this server.
  def configured?(%{"decision_id" => decision_id}), do: decision_id == :persistent_term.get({__MODULE__, :decision_id}, nil)
  def configured?(_params), do: false

  def join_delay_ms, do: :persistent_term.get({__MODULE__, :join_delay_ms}, 0)
  def join_started!, do: :persistent_term.put({__MODULE__, :join_state}, :joining)
  def join_completed!, do: :persistent_term.put({__MODULE__, :join_state}, :joined)

  def store_name, do: @store

  defp seed_decision! do
    unless Process.whereis(@store) do
      dir = Path.join(System.tmp_dir!(), "aiur-browser-command-answer-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      unless Process.whereis(IdGenerator) do
        {:ok, id_generator} = IdGenerator.start_link(path: Path.join(dir, "event-id.json"))
        Process.unlink(id_generator)
      end

      {:ok, pid} =
        DecisionStore.start_link(
          name: @store,
          state_dir: dir,
          dispatcher: fn _decision, _opts -> {:ok, %{status: :accepted}} end,
          dispatch_delay_ms: 60_000,
          filesystem_sync_fun: fn -> :ok end
        )

      Process.unlink(pid)
      System.at_exit(fn _ -> Aiur.TestCleanup.rm_rf!(dir) end)
    end

    case :persistent_term.get({__MODULE__, :decision_id}, nil) do
      nil ->
        {:ok, %{decision: decision}} =
          DecisionStore.request(
            %{
              "question" => "Should the browser fixture record this operator decision?",
              "blocking" => true,
              "authority" => "human_required",
              "reversibility" => "reversible",
              "context" => %{"authority_basis" => "security"},
              "options" => [%{"id" => "approve", "label" => "Approve"}]
            },
            [
              ticket: %{identifier: "BROWSER-5149", title: "Browser answer fixture", url: "https://example.invalid/5149"},
              source: %{agent_id: "browser-fixture", session_id: "browser-fixture", event_id: nil}
            ],
            @store
          )

        :persistent_term.put({__MODULE__, :decision_id}, decision.decision_id)
        decision

      decision_id ->
        {:ok, decision} = DecisionStore.get(decision_id, @store)
        decision
    end
  end
end

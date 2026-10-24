defmodule Aiur.TestSupport.BuildHome.ControlFixture do
  @moduledoc false
  alias Aiur.TestSupport.BuildHome.FixtureSource

  def reset do
    for {{__MODULE__, _id} = key, _state} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  def unit_row(id, opts) do
    with {:ok, data} <- FixtureSource.full(opts),
         row when not is_nil(row) <- Enum.find(data["sections"]["now"], &(&1["id"] == id)) do
      state = :persistent_term.get({__MODULE__, id}, row["agent"]["state"])
      {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "NODE-" <> id, "number" => String.to_integer(id)}, {"aiur-labs", "aiur"}, {"aiur-labs", "aiur"})
      {:ok, %{identity: identity, runtime: %{bucket: :running, work_state: if(state == "paused", do: :paused, else: :working)}}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def lifecycle(conn, %{"id" => id, "control" => action, "status" => status} = params)
      when action in ["pause", "resume"] and status in ["accepted", "applied", "rejected", "expired"] do
    action = String.to_existing_atom(action)
    status = String.to_existing_atom(status)
    if status == :applied, do: :persistent_term.put({__MODULE__, id}, if(action == :pause, do: "paused", else: "active"))
    rejection = if params["class"] == "stale_generation", do: %{class: :stale_generation}
    Aiur.AgentPubSub.broadcast_control_lifecycle(id, %{tracker_identity: %{identifier: id}, action: action, status: status, rejection: rejection, applied_at: DateTime.utc_now()})
    if status == :applied, do: diff(conn, id, action)
    Plug.Conn.send_resp(conn, 200, "build control lifecycle: #{params["status"]}")
  end

  def lifecycle(conn, _params), do: Plug.Conn.send_resp(conn, 422, "invalid lifecycle")

  defp diff(conn, id, action) do
    {:ok, row} = FixtureSource.ticket(id, [])
    row = put_in(row, ["agent", "state"], if(action == :pause, do: "paused", else: "active"))
    changes = %{now: System.system_time(:millisecond), upsert: [row], remove: [], set: %{}, resync: false}
    Phoenix.PubSub.broadcast(Aiur.PubSub, FixtureSource.topic(Plug.Conn.get_session(conn, "build_stream")), {:build_changes, changes})
  end
end

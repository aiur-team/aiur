defmodule AiurWeb.ConversationApiController do
  @moduledoc "Read-only authenticated conversation pages."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Conversation.{History, Ref, Session}
  alias Aiur.Executor.HarnessSession
  alias AiurWeb.{ConversationApiParams, EndpointConfig}
  alias AiurWeb.OperatorControlCenter.PayloadLoader
  alias Plug.Conn

  plug(:no_store)

  @spec entries(Conn.t(), map()) :: Conn.t()
  def entries(conn, %{"conversation_id" => id} = params) do
    with {:ok, opts} <- ConversationApiParams.entries(params),
         {:ok, page} <- History.list_entries(id, opts ++ [principal: principal(conn), reveal: params["reveal"] == "true"]) do
      json(conn, %{page | sessions: Enum.map(page.sessions, &Session.to_json/1)})
    else
      error -> failure(conn, error)
    end
  end

  @spec sessions(Conn.t(), map()) :: Conn.t()
  def sessions(conn, %{"conversation_id" => id}) do
    case History.list_sessions(id) do
      {:ok, sessions} -> json(conn, %{sessions: Enum.map(sessions, &Session.to_json/1)})
      error -> failure(conn, error)
    end
  end

  @spec anchors(Conn.t(), map()) :: Conn.t()
  def anchors(conn, %{"conversation_id" => id} = params) do
    with {:ok, opts} <- ConversationApiParams.anchors(params),
         {:ok, anchors} <- History.list_anchors(id, opts) do
      json(conn, %{anchors: anchors})
    else
      error -> failure(conn, error)
    end
  end

  @spec resolve(Conn.t(), map()) :: Conn.t()
  def resolve(conn, params) do
    case ConversationApiParams.subject(params) do
      {:ok, :executor} -> resolved(conn, resolve_executor(), "executor")
      {:ok, {owner, repository, identifier}} -> resolved(conn, resolve_worker(owner, repository, identifier), "worker")
      error -> failure(conn, error)
    end
  end

  defp resolve_executor do
    session = EndpointConfig.get(:conversation_executor_session_fun, &HarnessSession.current/0)

    case session.() do
      %{"state" => "live"} -> History.resolve_executor()
      _ -> {:error, :not_found}
    end
  end

  defp resolve_worker(owner, repository, identifier) do
    # The current Units projection can carry a newer display locator than subject.json.
    units = EndpointConfig.get(:conversation_units_fun, fn -> Map.get(PayloadLoader.load(:cached), :units, %{}) end)
    catalog = units.()
    rows = get_in(catalog, [:snapshot, :rows]) || []

    current =
      for %{identity: identity} <- rows,
          is_binary(identity.owner),
          is_binary(identity.repository),
          String.downcase(identity.owner) == String.downcase(owner),
          String.downcase(identity.repository) == String.downcase(repository),
          identity.identifier == identifier,
          {:ok, ref} <- [Ref.worker(identity)],
          {:ok, _} <- [History.list_sessions(ref)],
          do: Ref.conversation_id(ref)

    case History.resolve_worker(owner, repository, identifier) do
      {:ok, id} -> unique_subject([id | current])
      {:error, :ambiguous_subject, ids} -> unique_subject(ids ++ current)
      {:error, :not_found} -> unique_subject(current)
      error -> error
    end
  end

  defp unique_subject(ids) do
    case Enum.sort(Enum.uniq(ids)) do
      [] -> {:error, :not_found}
      [id] -> {:ok, id}
      ids -> {:error, :ambiguous_subject, ids}
    end
  end

  defp resolved(conn, {:ok, id}, subject), do: json(conn, %{conversation_id: id, subject: subject})

  defp resolved(conn, {:error, :ambiguous_subject, ids}, _subject),
    do: conn |> put_status(409) |> json(%{error: %{code: "ambiguous_subject", message: "Multiple conversations match", conversation_ids: ids}})

  defp resolved(conn, {:error, :not_found}, _subject), do: failure(conn, {:error, :subject_not_found})
  defp resolved(conn, error, _subject), do: failure(conn, error)

  @spec method_not_allowed_or_not_found(Conn.t(), map()) :: Conn.t()
  def method_not_allowed_or_not_found(conn, _params) do
    if conn.method in ["GET", "HEAD"] do
      failure(conn, {:error, :not_found})
    else
      conn |> put_resp_header("allow", "GET, HEAD") |> failure({:error, :method_not_allowed})
    end
  end

  defp principal(%{assigns: %{device_id: id}}) when is_binary(id), do: {:device, id}
  defp principal(%{assigns: %{token_name: _name}}), do: {:operator, :basic_auth}
  defp principal(%{remote_ip: {127, _, _, _}}), do: {:operator, :loopback}
  defp principal(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: {:operator, :loopback}
  defp principal(_conn), do: {:operator, :basic_auth}

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  defp failure(conn, {:error, reason}) do
    {status, code} =
      case reason do
        :not_found -> {404, "conversation_not_found"}
        :subject_not_found -> {404, "subject_not_found"}
        :unavailable -> {503, "conversation_unavailable"}
        :method_not_allowed -> {405, "method_not_allowed"}
        reason when reason in [:invalid_cursor, :invalid_limit, :invalid_subject, :invalid_range, :invalid_kinds] -> {422, Atom.to_string(reason)}
      end

    conn |> put_status(status) |> json(%{error: %{code: code, message: String.replace(code, "_", " ")}})
  end
end

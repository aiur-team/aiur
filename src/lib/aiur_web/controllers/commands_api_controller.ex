defmodule AiurWeb.CommandsApiController do
  @moduledoc """
  End-user Commands API for an embedding host application.

  Reads and answers are scoped by the bearer grant resolved in
  `AiurWeb.CommandsScopeAuth`; the controller never accepts a ticket set from
  request content. It owns only the HTTP vocabulary: the domain decisions live
  in `Aiur.Commands.HostApi` and the component contract in
  `Aiur.Commands.ComponentState`. A Command's typed media is read through the
  same grant on `:media`, which re-checks the Command's own attachment list.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Commands.{ComponentState, HostApi, Scope}
  alias AiurWeb.CommandMediaResponse
  alias AiurWeb.CommandsScopeAuth
  alias Plug.Conn

  @default_expiry_seconds 900

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    case scope(conn) do
      {:ok, scope} -> conn |> invoke(:list, [scope, params, api_opts(conn)]) |> render_read(conn)
      :error -> unauthorized(conn)
    end
  end

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"decision_id" => decision_id}) do
    case scope(conn) do
      {:ok, scope} -> conn |> invoke(:show, [scope, decision_id, api_opts(conn)]) |> render_read(conn)
      :error -> unauthorized(conn)
    end
  end

  @spec answer(Conn.t(), map()) :: Conn.t()
  def answer(conn, %{"decision_id" => decision_id} = params) do
    case scope(conn) do
      {:ok, scope} -> answer_with_scope(conn, scope, decision_id, Map.delete(params, "decision_id"))
      :error -> unauthorized(conn)
    end
  end

  @spec reject(Conn.t(), map()) :: Conn.t()
  def reject(conn, params), do: act(conn, :reject, params)

  @spec escalate(Conn.t(), map()) :: Conn.t()
  def escalate(conn, params), do: act(conn, :escalate, params)

  defp act(conn, action, %{"decision_id" => decision_id} = params) do
    case scope(conn) do
      {:ok, scope} ->
        case invoke(conn, action, [scope, decision_id, Map.delete(params, "decision_id"), api_opts(conn)]) do
          {:ok, body} -> json(conn, body)
          {:error, reason} -> render_answer_error(conn, reason)
        end

      :error ->
        unauthorized(conn)
    end
  end

  @doc """
  Serves one media attachment of a scoped Command.

  The grant's ticket set is re-checked on every read and the attachment must
  belong to that Command, so a host cannot fetch media by guessing an id. The
  response itself (redirect, contained file, hardening headers) comes from
  `AiurWeb.CommandMediaResponse`, the same module the dashboard route uses.
  """
  @spec media(Conn.t(), map()) :: Conn.t()
  def media(conn, %{"decision_id" => decision_id, "attachment_id" => attachment_id}) do
    case scope(conn) do
      {:ok, scope} ->
        result = invoke(conn, :media, [scope, decision_id, attachment_id, api_opts(conn)])
        CommandMediaResponse.respond(conn, result)

      :error ->
        unauthorized(conn)
    end
  end

  defp answer_with_scope(conn, scope, decision_id, payload) do
    case invoke(conn, :answer, [scope, decision_id, payload, api_opts(conn)]) do
      {:ok, body} -> json(conn, body)
      {:error, reason} -> render_answer_error(conn, reason)
    end
  end

  @doc """
  Mints a scoped grant for a host's end user.

  Only the supervisor credential may call this route: it is the credential the
  host already holds server-side, and the grant it receives is what the end
  user's client may carry. The body names an explicit ticket set, a label
  scope such as `game:chess`, or both.
  """
  @spec mint_scope(Conn.t(), map()) :: Conn.t()
  def mint_scope(conn, params) do
    with {:ok, secret} <- CommandsScopeAuth.signing_secret(conn),
         {:ok, principal} <- required_string(params, "principal"),
         {:ok, tickets} <- optional_tickets(params),
         {:ok, labels} <- optional_labels(params),
         {:ok, expires_in} <- expires_in(params),
         {:ok, minted} <-
           Scope.mint(principal, tickets, secret: secret, expires_in: expires_in, labels: labels) do
      conn
      |> put_status(201)
      |> json(%{
        "token" => minted.token,
        "expires_at" => DateTime.to_iso8601(minted.scope.expires_at),
        "scope" => Scope.to_public(minted.scope)
      })
    else
      {:error, :invalid_scope} -> error(conn, 422, "invalid_scope", "Scope request is invalid")
      _unavailable -> error(conn, 503, "commands_scope_unavailable", "Command scopes are unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error(conn, 404, "not_found", "Route not found")
  end

  defp render_read({:ok, body}, conn), do: json(conn, body)

  defp render_read({:error, :not_found}, conn), do: error(conn, 404, "command_not_found", "Command not found")
  defp render_read({:error, :store_unavailable}, conn), do: unavailable(conn)

  defp render_read({:error, {:invalid_query, _detail}}, conn),
    do: error(conn, 422, "invalid_request", "Command query is invalid")

  defp render_read({:error, _reason}, conn), do: unavailable(conn)

  defp render_answer_error(conn, :not_found), do: error(conn, 404, "command_not_found", "Command not found")
  defp render_answer_error(conn, :store_unavailable), do: unavailable(conn)

  defp render_answer_error(conn, {:invalid_answer, detail}) do
    conn
    |> put_status(422)
    |> json(%{
      "error" => %{"code" => "invalid_request", "message" => "Command answer is invalid"},
      "command" => ComponentState.error(:validation_failed, "Answer failed validation", reason: detail)
    })
  end

  defp render_answer_error(conn, {:conflict, detail}) do
    conn
    |> put_status(409)
    |> json(%{
      "error" => %{"code" => "command_conflict", "message" => "Command state changed; refresh and retry"},
      "command" => ComponentState.error(:conflict, "Command state changed; refresh and retry", reason: detail)
    })
  end

  defp render_answer_error(conn, _reason), do: unavailable(conn)

  defp unavailable(conn), do: error(conn, 503, "commands_unavailable", "Command service is unavailable")

  defp unauthorized(conn), do: error(conn, 401, "commands_scope_required", "A Command scope token is required")

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => %{"code" => code, "message" => message}})
  end

  defp scope(conn) do
    case conn.assigns[:command_scope] do
      %{ticket_set: %MapSet{}} = scope -> {:ok, scope}
      _missing -> :error
    end
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, :invalid_scope}
    end
  end

  defp optional_tickets(params) do
    case Map.get(params, "tickets") do
      nil -> {:ok, []}
      tickets when is_list(tickets) -> if Enum.all?(tickets, &is_binary/1), do: {:ok, tickets}, else: {:error, :invalid_scope}
      _invalid -> {:error, :invalid_scope}
    end
  end

  # A label scope such as `game:chess` lets a host authorize a game without
  # enumerating its tickets; explicit tickets and labels may be combined.
  defp optional_labels(params) do
    case Map.get(params, "labels") do
      nil -> {:ok, []}
      labels when is_list(labels) -> if Enum.all?(labels, &is_binary/1), do: {:ok, labels}, else: {:error, :invalid_scope}
      _invalid -> {:error, :invalid_scope}
    end
  end

  defp expires_in(params) do
    case Map.get(params, "expires_in", @default_expiry_seconds) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, :invalid_scope}
    end
  end

  defp host_api(conn), do: conn.private[:host_api] || HostApi

  defp api_opts(conn) do
    conn.private
    |> Map.get(:host_api_opts, [])
    |> maybe_put(:store, conn.private[:command_store])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp invoke(conn, operation, args) do
    apply(host_api(conn), operation, args)
  rescue
    _error -> {:error, :store_unavailable}
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end
end

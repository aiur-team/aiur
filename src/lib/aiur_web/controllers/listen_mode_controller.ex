defmodule AiurWeb.ListenModeController do
  @moduledoc "Authenticated listener-mode reads and compare-and-set writes."
  use Phoenix.Controller, formats: [:json]
  alias Aiur.Listener
  alias Plug.Conn

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"issue_identifier" => ticket}), do: respond(conn, Listener.get_mode(ticket))

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, %{"issue_identifier" => ticket} = params) do
    mode = Map.get(params, "mode")
    actor = Map.get(params, "actor", "human")

    result =
      cond do
        mode not in ["steer", "sync", "async"] ->
          {:error, :invalid_mode}

        actor not in ["human", "executor"] ->
          {:error, :invalid_actor}

        true ->
          Listener.set_mode(ticket, String.to_existing_atom(mode),
            expected_version: params["expected_version"],
            idempotency_key: params["idempotency_key"],
            actor: String.to_existing_atom(actor)
          )
      end

    respond(conn, result)
  end

  defp respond(conn, {:ok, record}), do: json(conn, Map.put(record, :routing, Listener.routing()))
  defp respond(conn, {:error, {:mode_conflict, current}}), do: conn |> put_status(409) |> json(%{error: "mode_conflict", current: current})
  defp respond(conn, {:error, :issue_not_found}), do: conn |> put_status(404) |> json(%{error: "issue_not_found"})
  defp respond(conn, {:error, {:outcome_unknown, info}}), do: conn |> put_status(503) |> json(%{error: "outcome_unknown", idempotency_key: info.idempotency_key})
  defp respond(conn, {:error, reason}) when reason in [:timeout, :unavailable], do: conn |> put_status(503) |> json(%{error: reason})
  defp respond(conn, {:error, reason}) when is_atom(reason), do: conn |> put_status(422) |> json(%{error: reason})
  defp respond(conn, {:error, _reason}), do: conn |> put_status(503) |> json(%{error: "listen_mode_unavailable"})

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params), do: conn |> put_resp_header("allow", "GET, POST") |> put_status(405) |> json(%{error: "method_not_allowed"})
end

defmodule AiurWeb.Api.MemoryIssueController do
  @moduledoc "Development-only endpoint for adding issues to the in-memory tracker."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.{Issue, Memory.Tracker}

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    if Aiur.Config.tracker_kind() != "memory" do
      error(conn, 404, "not_found", "Memory issue seeding is only available with tracker.kind: memory")
    else
      with {:ok, issue} <- build_issue(params),
           :ok <- Tracker.add_issue(issue) do
        conn
        |> put_status(:created)
        |> json(%{issue: %{id: issue.id, identifier: issue.identifier}})
      else
        {:error, {:invalid_field, field}} -> error(conn, 422, "invalid_field", "Invalid or missing field: #{field}")
        {:error, :duplicate_id} -> error(conn, 409, "duplicate_id", "An issue with this id already exists")
        {:error, :duplicate_identifier} -> error(conn, 409, "duplicate_identifier", "An issue with this identifier already exists")
      end
    end
  rescue
    ArgumentError -> error(conn, 404, "not_found", "Memory issue seeding is only available with tracker.kind: memory")
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "POST")
    |> error(405, "method_not_allowed", "Method not allowed")
  end

  defp build_issue(params) when is_map(params) do
    with {:ok, id} <- required_string(params, "id"),
         {:ok, identifier} <- required_string(params, "identifier"),
         {:ok, title} <- required_string(params, "title"),
         {:ok, description} <- required_string(params, "description"),
         {:ok, state} <- required_string(params, "state"),
         {:ok, labels} <- string_list(params, "labels"),
         {:ok, blocked_by} <- blocked_by(params) do
      {:ok, %Issue{id: id, identifier: identifier, title: title, description: description, state: state, labels: labels, blocked_by: blocked_by}}
    end
  end

  defp build_issue(_params), do: {:error, {:invalid_field, "id"}}

  defp required_string(params, field) do
    case Map.get(params, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, field}}
    end
  end

  defp string_list(params, field) do
    case Map.get(params, field) do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: {:error, {:invalid_field, field}}

      _ ->
        {:error, {:invalid_field, field}}
    end
  end

  defp blocked_by(params) do
    case Map.get(params, "blocked_by", []) do
      values when is_list(values) ->
        collect_blockers(values)

      _ ->
        {:error, {:invalid_field, "blocked_by"}}
    end
  end

  defp collect_blockers(values) do
    values
    |> Enum.reduce_while({:ok, []}, &collect_blocker/2)
    |> reverse_blockers()
  end

  defp collect_blocker(%{"id" => id, "state" => state}, {:ok, acc}) when is_binary(id) and id != "" and is_binary(state),
    do: {:cont, {:ok, [%{id: id, state: state} | acc]}}

  defp collect_blocker(_value, _acc), do: {:halt, {:error, {:invalid_field, "blocked_by"}}}

  defp reverse_blockers({:ok, entries}), do: {:ok, Enum.reverse(entries)}
  defp reverse_blockers(error), do: error

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end

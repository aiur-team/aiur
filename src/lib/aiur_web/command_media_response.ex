defmodule AiurWeb.CommandMediaResponse do
  @moduledoc """
  Turns one resolved Command media item into an HTTP response.

  Shared by the dashboard Command route and the ticket-scoped Commands API route
  so the two cannot drift on read-time safety:

    * a local file must still canonicalize (symlink-resolved) inside a configured
      safe root *now*, because a symlink swapped after ingestion would otherwise
      escape containment;
    * an already-public https locator answers with a redirect instead of an
      authenticated proxy hop;
    * every response carries `nosniff` and a deny-all content policy so a served
      file cannot be reinterpreted as active content by the browser;
    * a missing or unresolvable item is a plain 404 that does not confirm the
      Command or the attachment exists.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Commands.Media
  alias Aiur.{DecisionValidation, PathSafety}
  alias Plug.Conn

  @doc "Serves a resolved item, or renders the matching error response."
  @spec respond(Conn.t(), {:ok, Media.item()} | {:error, term()}) :: Conn.t()
  def respond(conn, {:ok, item}), do: serve(conn, item)
  def respond(conn, {:error, :store_unavailable}), do: service_unavailable(conn)
  def respond(conn, {:error, _reason}), do: not_found(conn)

  defp serve(conn, item) do
    case Media.fetch_field(item, :locator) do
      %{kind: :url, value: url} -> redirect(conn, external: url)
      %{"kind" => "url", "value" => url} when is_binary(url) -> redirect(conn, external: url)
      %{kind: :path, value: path} -> serve_file(conn, path, mime_type(item))
      _missing -> not_found(conn)
    end
  end

  defp serve_file(conn, path, mime_type) do
    case contained(path) do
      {:ok, canonical} ->
        conn
        |> Conn.put_resp_header("x-content-type-options", "nosniff")
        |> Conn.put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> Conn.put_resp_header("cache-control", "private, max-age=60")
        |> Conn.put_resp_content_type(mime_type)
        |> Conn.send_file(200, canonical)

      {:error, _reason} ->
        not_found(conn)
    end
  end

  defp contained(path) do
    Enum.find_value(DecisionValidation.safe_roots(), {:error, :outside_root}, fn root ->
      case PathSafety.contained?(root, path) do
        {:ok, %{candidate: canonical}} -> {:ok, canonical}
        {:error, _reason} -> nil
      end
    end)
  end

  defp mime_type(item), do: Media.fetch_field(item, :mime_type) || "application/octet-stream"

  defp not_found(conn) do
    conn
    |> Conn.put_status(404)
    |> json(%{error: %{code: "media_not_found", message: "Media not found"}})
  end

  defp service_unavailable(conn) do
    conn
    |> Conn.put_status(503)
    |> json(%{error: %{code: "decision_store_unavailable", message: "Decision store unavailable"}})
  end
end

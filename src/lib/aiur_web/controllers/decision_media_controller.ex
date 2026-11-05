defmodule AiurWeb.DecisionMediaController do
  @moduledoc """
  Serves one media attachment that belongs to a Command.

  Authentication and authorization are the router's Decision read pipeline, so
  this route is reachable exactly by the identities that can already read the
  Command. This controller adds the media boundary that must be re-checked at
  read time, not only at ingestion:

    * the attachment must be one of *this* Decision's prompt, option or answer
      media items, so an attachment id from another Command never resolves;
    * a local file must still canonicalize (symlink-resolved) inside a
      configured safe root *now*, because a symlink swapped after ingestion
      would otherwise escape containment;
    * an already-public https locator answers with a redirect instead of an
      authenticated proxy hop.

  Responses always carry `nosniff` and a deny-all content policy so a served
  file cannot be reinterpreted as active content by the browser.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Commands.Media
  alias Aiur.{DecisionStore, DecisionValidation, PathSafety}
  alias Plug.Conn

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"decision_id" => decision_id, "attachment_id" => attachment_id}) do
    with {:ok, decision} <- fetch(conn, decision_id),
         {:ok, item} <- Media.find_attachment(Media.all_items(decision), attachment_id) do
      serve(conn, item)
    else
      :error -> not_found(conn)
      {:error, :store_unavailable} -> service_unavailable(conn)
      {:error, _reason} -> not_found(conn)
    end
  end

  defp serve(conn, item) do
    case locator(item) do
      %{kind: :url, value: url} -> redirect(conn, external: url)
      %{kind: :path, value: path} -> serve_file(conn, path, mime_type(item))
      _missing -> not_found(conn)
    end
  end

  defp serve_file(conn, path, mime_type) do
    case contained(path) do
      {:ok, canonical} ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> put_resp_header("cache-control", "private, max-age=60")
        |> put_resp_content_type(mime_type)
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

  defp locator(item), do: Media.fetch_field(item, :locator)
  defp mime_type(item), do: Media.fetch_field(item, :mime_type) || "application/octet-stream"

  defp fetch(conn, decision_id) do
    DecisionStore.get(decision_id, Map.get(conn.private, :decision_media_store, DecisionStore))
  rescue
    _error -> {:error, :store_unavailable}
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: %{code: "media_not_found", message: "Media not found"}})
  end

  defp service_unavailable(conn) do
    conn
    |> put_status(503)
    |> json(%{error: %{code: "decision_store_unavailable", message: "Decision store unavailable"}})
  end
end

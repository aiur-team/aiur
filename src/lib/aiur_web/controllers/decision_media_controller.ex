defmodule AiurWeb.DecisionMediaController do
  @moduledoc """
  Serves one media attachment that belongs to a Command.

  Authentication and authorization are the router's Decision read pipeline, so
  this route is reachable exactly by the identities that can already read the
  Command. This controller adds the media boundary that must be re-checked at
  read time, not only at ingestion:

    * the attachment must be one of *this* Decision's prompt, option or answer
      media items, so an attachment id from another Command never resolves;
    * the file/redirect/header handling lives in `AiurWeb.CommandMediaResponse`,
      which the ticket-scoped Commands API route shares, so both serving paths
      re-check safe-root containment and emit the same hardening headers.

  Responses always carry `nosniff` and a deny-all content policy so a served
  file cannot be reinterpreted as active content by the browser.
  """

  use Phoenix.Controller, formats: [:json]

  alias Aiur.Commands.Media
  alias Aiur.DecisionStore
  alias AiurWeb.CommandMediaResponse
  alias Plug.Conn

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, %{"decision_id" => decision_id, "attachment_id" => attachment_id}) do
    result = conn |> fetch(decision_id) |> find(attachment_id)
    CommandMediaResponse.respond(conn, result)
  end

  defp find({:ok, decision}, attachment_id) do
    case Media.find_attachment(Media.all_items(decision), attachment_id) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, :not_found}
    end
  end

  defp find({:error, _reason} = error, _attachment_id), do: error

  defp fetch(conn, decision_id) do
    DecisionStore.get(decision_id, Map.get(conn.private, :decision_media_store, DecisionStore))
  rescue
    _error -> {:error, :store_unavailable}
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end
end

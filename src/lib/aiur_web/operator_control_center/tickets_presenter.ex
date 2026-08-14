defmodule AiurWeb.OperatorControlCenter.TicketsPresenter do
  @moduledoc """
  Presents the repository's open tickets for the Units page Tickets panel.

  Provider reads happen in `load/1`; row shaping, token derivation, and lookup
  stay pure so rendering never reaches a provider. A failed or unread source is
  reported by name — the panel shows a stale or unavailable region instead of an
  empty table that reads as "no open tickets".
  """

  alias Aiur.OpenTicketSource
  alias Aiur.OpenTicketSource.Snapshot
  alias AiurWeb.OperatorControlCenter.{AgentRoutingPreview, RowToken}

  @type status :: :ready | :empty | :stale | :unavailable | :unsupported

  @spec load(keyword()) :: map()
  def load(opts \\ []) do
    opts
    |> Keyword.get(:tickets_fun, &OpenTicketSource.snapshot/0)
    |> read()
    |> project()
  end

  @doc "Accepts an already-projected view, or anything else as an unavailable one."
  @spec normalize(map() | term()) :: map()
  def normalize(%{status: status, rows: rows} = view) when is_atom(status) and is_list(rows), do: view
  def normalize(_view), do: project(%Snapshot{})

  @spec project(Snapshot.t() | term()) :: map()
  def project(%Snapshot{} = snapshot) do
    # A ticket whose identity will not join cannot be addressed by token, so its
    # row could neither open a modal nor carry a unique DOM id. Dropping it is
    # honest; rendering a dead row is not.
    rows = snapshot.tickets |> Enum.map(&row/1) |> Enum.reject(&is_nil(&1.token))
    status = status(snapshot.status, rows)

    %{
      status: status,
      message: message(status),
      observed_at: snapshot.observed_at,
      generation: snapshot.generation,
      truncated?: snapshot.truncated?,
      rows: rows,
      total_count: length(rows)
    }
  end

  def project(_snapshot), do: project(%Snapshot{})

  @doc "Returns the opaque, stable lookup token for one presented row."
  @spec row_token(map()) :: String.t() | nil
  def row_token(row), do: RowToken.for(row)

  @spec lookup(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(%{rows: rows}, token) when is_list(rows) and is_binary(token) do
    case Enum.find(rows, &(&1.token == token)) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def lookup(_view, _token), do: {:error, :not_found}

  @doc "The count label the panel header shows, matching the Models panel phrasing."
  @spec count_label(map()) :: String.t()
  def count_label(%{status: :unavailable}), do: "tickets unavailable"
  def count_label(%{status: :unsupported}), do: "not a GitHub tracker"

  # A truncated listing is a lower bound, never an exact count.
  def count_label(%{truncated?: true} = view), do: "at least " <> ticket_phrase(view)
  def count_label(%{total_count: count} = view) when is_integer(count), do: ticket_phrase(view)
  def count_label(_view), do: "tickets unavailable"

  defp ticket_phrase(%{total_count: 1}), do: "1 ticket"
  defp ticket_phrase(%{total_count: count}), do: "#{count} tickets"

  defp read(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _error -> %Snapshot{}
  catch
    _kind, _reason -> %Snapshot{}
  end

  defp read(_fun), do: %Snapshot{}

  defp row(ticket) do
    labels = List.wrap(Map.get(ticket, :labels))

    row = %{
      identity: Map.get(ticket, :identity),
      identifier: Map.get(ticket, :identifier),
      title: Map.get(ticket, :title),
      url: Map.get(ticket, :url),
      state: Map.get(ticket, :state),
      labels: labels,
      assignee: Map.get(ticket, :assignee),
      created_at: Map.get(ticket, :created_at),
      updated_at: Map.get(ticket, :updated_at),
      routing: AgentRoutingPreview.preview(labels)
    }

    Map.put(row, :token, row_token(row))
  end

  defp status(:unsupported, _rows), do: :unsupported
  defp status(:unavailable, _rows), do: :unavailable
  defp status(:stale, _rows), do: :stale
  defp status(_available, []), do: :empty
  defp status(_available, _rows), do: :ready

  defp message(:empty), do: "No open tickets on this repository."
  defp message(:stale), do: "Showing the last-known-good open tickets; the tracker listing did not refresh."
  defp message(:unavailable), do: "Open tickets are unavailable."
  defp message(:unsupported), do: "Open tickets are listed for GitHub trackers only."
  defp message(_ready), do: nil
end

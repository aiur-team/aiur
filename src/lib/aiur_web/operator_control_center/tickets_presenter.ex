defmodule AiurWeb.OperatorControlCenter.TicketsPresenter do
  @moduledoc """
  Presents the repository's open tickets for the Units page Tickets panel.

  Provider reads happen in `load/1`; row shaping, token derivation, and lookup
  stay pure so rendering never reaches a provider. A failed or unread source is
  reported by name — the panel shows a stale or unavailable region instead of an
  empty table that reads as "no open tickets".

  `search/2` narrows a projected view. It is deliberately applied to the whole
  projection rather than to a rendered page: the panel reveals rows in batches,
  and a filter that only saw the revealed batch would answer a question the
  operator did not ask. The unfiltered view stays the source of truth for
  lookups, so a row hidden by the current query still resolves when a modal or
  ticket context is already open on it.
  """

  alias Aiur.OpenTicketSource
  alias Aiur.OpenTicketSource.Snapshot
  alias AiurWeb.OperatorControlCenter.{AgentRoutingPreview, RowToken, TicketSearch}

  @type status :: :ready | :empty | :no_matches | :stale | :unavailable | :unsupported

  # A busy repository lists dozens of open tickets. The panel opens on a glance-
  # sized batch and reveals more on request, so the Units page stays scannable.
  @initial_reveal 5

  # The first reveal is the operator saying "I want to read the backlog", so the
  # step widens: 5 -> 15 -> 25 reaches a 25-ticket repo in two clicks, not four.
  @reveal_step 10

  @doc "How many ticket rows the panel shows before the operator asks for more."
  @spec initial_reveal() :: pos_integer()
  def initial_reveal, do: @initial_reveal

  @doc "The row count after one more reveal, given the count shown now."
  @spec reveal_more(term()) :: pos_integer()
  def reveal_more(visible) when is_integer(visible) and visible >= @initial_reveal, do: visible + @reveal_step
  def reveal_more(_visible), do: @initial_reveal

  @spec load(keyword()) :: map()
  def load(opts \\ []) do
    opts
    |> Keyword.get(:tickets_fun, &OpenTicketSource.snapshot/0)
    |> read()
    |> project()
  end

  @doc "Accepts an already-projected view, or anything else as an unavailable one."
  @spec normalize(map() | term()) :: map()
  def normalize(%{status: status, rows: rows} = view) when is_atom(status) and is_list(rows) do
    # A view projected before search existed still has to be searchable, so the
    # search keys are filled rather than assumed.
    view
    |> Map.put_new(:query, "")
    |> Map.put_new(:match_count, length(rows))
    |> Map.put_new(:search_status, :inactive)
    |> Map.put_new(:search_message, nil)
    |> Map.put_new(:total_count, length(rows))
    |> Map.put_new(:all_rows, rows)
    |> Map.put_new(:truncated?, false)
  end

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
      # The unfiltered projection is retained by reference so `search/2` always
      # narrows the backlog rather than whatever the last query left behind.
      all_rows: rows,
      total_count: length(rows),
      query: "",
      match_count: length(rows),
      search_status: :inactive,
      search_message: nil
    }
  end

  def project(_snapshot), do: project(%Snapshot{})

  @doc """
  Returns the view narrowed to the tickets matching `query`, best match first.

  A query with no comparable terms returns the view untouched, so clearing the
  input restores the full list without a provider read. Search state is kept in
  `search_status` rather than folded into `status`: a stale listing that the
  operator then searches is still stale, and collapsing the two would trade the
  "did not refresh" warning for a "no matches" one.
  """
  @spec search(map(), String.t() | nil) :: map()
  def search(view, query) do
    view = normalize(view)
    # The raw query is what the input echoes back, so it is stored untouched: a
    # trimmed echo would delete the space an operator just typed between two
    # terms, out from under their caret.
    query = raw_query(query)

    # A listing with no rows has nothing to search, and reporting a surviving
    # query as "no matches" would blame it for the provider's state.
    if view.all_rows == [] or TicketSearch.terms(query) == [] do
      %{view | query: query, rows: view.all_rows, match_count: length(view.all_rows), search_status: :inactive, search_message: nil}
    else
      matches = TicketSearch.filter(view.all_rows, query)
      search_status = if matches == [], do: :no_matches, else: :matched

      %{
        view
        | query: query,
          rows: matches,
          match_count: length(matches),
          search_status: search_status,
          search_message: search_message(search_status, view, query)
      }
    end
  end

  @doc "The visually hidden result announcement, so filtering is audible to a screen reader."
  @spec search_announcement(map()) :: String.t()
  # An idle panel says nothing. This region sits beside the fleet's own status
  # region, and the open-ticket poll runs every couple of minutes: announcing
  # the unfiltered total would make an untouched dashboard talk to itself.
  def search_announcement(%{search_status: :no_matches} = view), do: view.search_message || ""

  def search_announcement(%{search_status: :matched, match_count: matches, total_count: total}),
    do: "#{matches} of #{ticket_word(total)} match."

  def search_announcement(_view), do: ""

  # A truncated listing is a bounded prefix of the backlog, so "no tickets
  # match" would be a claim about tickets this search never saw.
  defp search_message(:no_matches, %{truncated?: true, total_count: total}, query),
    do: "No match for “#{query}” in the first #{ticket_word(total)} listed."

  defp search_message(:no_matches, _view, query), do: "No tickets match “#{query}”."
  defp search_message(_search_status, _view, _query), do: nil

  defp raw_query(query) when is_binary(query), do: query
  defp raw_query(_query), do: ""

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

  # While a search is active the header has to answer "how much of the backlog
  # am I looking at" — a bare match count reads as the whole backlog shrinking.
  def count_label(%{search_status: search_status, match_count: matches} = view)
      when search_status in [:matched, :no_matches] and is_integer(matches),
      do: "#{matches} of " <> count_label(%{view | search_status: :inactive})

  # A truncated listing is a lower bound, never an exact count.
  def count_label(%{truncated?: true} = view), do: "at least " <> ticket_phrase(view)
  def count_label(%{total_count: count} = view) when is_integer(count), do: ticket_phrase(view)
  def count_label(_view), do: "tickets unavailable"

  defp ticket_phrase(%{total_count: count}), do: ticket_word(count)

  defp ticket_word(1), do: "1 ticket"
  defp ticket_word(count), do: "#{count} tickets"

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
      body_excerpt: Map.get(ticket, :body_excerpt),
      url: Map.get(ticket, :url),
      state: Map.get(ticket, :state),
      labels: labels,
      assignee: Map.get(ticket, :assignee),
      created_at: Map.get(ticket, :created_at),
      updated_at: Map.get(ticket, :updated_at),
      routing: AgentRoutingPreview.preview(labels)
    }

    # Indexed here, once per provider read, rather than inside the filter: the
    # operator's query changes on every keystroke, the tickets do not.
    row
    |> Map.put(:token, row_token(row))
    |> TicketSearch.put_index()
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

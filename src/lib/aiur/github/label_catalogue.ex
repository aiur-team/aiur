defmodule Aiur.GitHub.LabelCatalogue do
  @moduledoc """
  The repository's label descriptions, as GitHub reports them for the labels
  themselves.

  The Features view names a row from its registry label, then the label's
  description, then the title-cased slug. Both cheaper sources of that description
  are per-ticket observations: the open-issue label snapshot covers only labels an
  open ticket wears right now, and a history row covers only the descriptions it
  captured when that row was last read. A feature whose tickets all merged before
  descriptions were captured — or whose rows were persisted without them — has no
  description in either place and falls through to its slug ("Mp E7").

  This catalogue is the label's own record: one listing of the repository's labels,
  independent of ticket state. Reads are local (an ETS table this module's
  supervised process owns); the refresh runs on a timer through an injected request
  function. A failed or partial listing leaves the last catalogue in place, and a
  read older than the caller's bound answers `:none`, so the naming chain falls back
  to the per-ticket sources rather than showing nothing.
  """

  use GenServer
  require Logger
  alias Aiur.GitHub.Access

  @table __MODULE__
  @topic "github:label_catalogue"
  @default_refresh_ms 3_600_000
  # A repository label set is a few pages at 100 labels a page. The cap bounds a
  # pathological listing instead of paging a runaway endpoint forever.
  @per_page 100
  @max_pages 10

  @type descriptions :: %{String.t() => String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The PubSub topic a successful refresh broadcasts on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Reads the repository's labels and records their descriptions.

  Every page must succeed: a partial listing would name only some labels, so a
  failed page leaves the previous catalogue untouched. Options carry the injectable
  seams used by tests and by the supervised refresh — `:request_fun`, `:owner`,
  `:repo`, `:token`, `:base_url`.
  """
  @spec refresh(keyword()) :: :ok | {:error, term()}
  def refresh(opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
    base_url = Keyword.get(opts, :base_url, Access.base_url())

    with {:ok, owner, repo} <- repo(opts),
         {:ok, token} <- Access.require_token(opts),
         {:ok, labels} <- fetch_labels(request_fun, base_url, owner, repo, token) do
      record(owner, repo, descriptions(labels))
    end
  end

  @doc "Records `descriptions` for `owner/repo` as the catalogue read at `taken_at_ms`."
  @spec record(String.t(), String.t(), descriptions(), integer() | nil) :: :ok
  def record(owner, repo, descriptions, taken_at_ms \\ nil) when is_binary(owner) and is_binary(repo) and is_map(descriptions) do
    taken = if is_integer(taken_at_ms), do: taken_at_ms, else: now_ms()
    :ets.insert(@table, {repo_key(owner, repo), descriptions, taken})
    broadcast(taken)
    :ok
  rescue
    # No table: the process is not running. A dropped catalogue only costs the
    # naming chain its repository-wide source; the per-ticket sources still answer.
    ArgumentError -> :ok
  end

  @doc """
  The catalogue for `owner/repo` and when it was read, or `:none` when there is
  none or it is older than `max_age_ms`.
  """
  @spec fetch(String.t(), String.t(), pos_integer()) :: {:ok, descriptions(), integer()} | :none
  def fetch(owner, repo, max_age_ms) when is_binary(owner) and is_binary(repo),
    do: read_catalogue(repo_key(owner, repo), max_age_ms)

  @doc "`fetch/3` for the configured repository; `:none` when none is configured."
  @spec fetch(pos_integer()) :: {:ok, descriptions(), integer()} | :none
  def fetch(max_age_ms) when is_integer(max_age_ms) do
    case Access.parse_repo() do
      {:ok, {owner, repo}} -> fetch(owner, repo, max_age_ms)
      {:error, _reason} -> :none
    end
  end

  @doc "Removes every catalogue. For tests."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    state = %{opts: opts, timer: nil}

    if refresh?(opts), do: {:ok, state, {:continue, :refresh}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, schedule_refresh(refresh_now(state))}

  @impl true
  def handle_info(:refresh_tick, state), do: {:noreply, schedule_refresh(refresh_now(state))}
  def handle_info(_message, state), do: {:noreply, state}

  defp refresh?(opts) do
    Keyword.get_lazy(opts, :refresh?, fn -> Application.get_env(:aiur, :label_catalogue_refresh?, true) end)
  end

  defp refresh_now(state) do
    case refresh(state.opts) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("label_catalogue refresh_failed=#{inspect(reason, limit: 20, printable_limit: 200)}")
        state
    end
  end

  defp schedule_refresh(%{opts: opts} = state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    interval = Keyword.get(opts, :refresh_ms, @default_refresh_ms)
    %{state | timer: Process.send_after(self(), :refresh_tick, interval)}
  end

  defp repo(opts) do
    case {Keyword.get(opts, :owner), Keyword.get(opts, :repo)} do
      {owner, repo} when is_binary(owner) and is_binary(repo) -> {:ok, owner, repo}
      _configured -> with {:ok, {owner, repo}} <- Access.parse_repo(), do: {:ok, owner, repo}
    end
  end

  defp fetch_labels(request_fun, base_url, owner, repo, token) do
    url = "#{base_url}/repos/#{owner}/#{repo}/labels?per_page=#{@per_page}"
    fetch_page(request_fun, url, token, 1, [])
  end

  defp fetch_page(_request_fun, _url, _token, page, _acc) when page > @max_pages,
    do: {:error, {:label_catalogue_too_large, @max_pages * @per_page}}

  defp fetch_page(request_fun, url, token, page, acc) do
    request = %{method: :get, url: page_url(url, page), token: token, caller: "label_catalogue_refresh"}

    case request_fun.(request) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        labels = acc ++ body
        if length(body) < @per_page, do: {:ok, labels}, else: fetch_page(request_fun, url, token, page + 1, labels)

      {:ok, %{status: 200} = response} ->
        {:error, {:label_catalogue_response, Map.get(response, :body)}}

      {:ok, %{status: _status} = response} ->
        {:error, Access.github_status_error(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page_url(url, page), do: url <> "&page=#{page}"

  # Only a label that carries a non-empty description names anything; a label with
  # none is absent from the map, so the chain keeps falling through to the slug.
  defp descriptions(labels) when is_list(labels) do
    for %{"name" => name, "description" => description} <- labels,
        is_binary(name) and is_binary(description) and description != "",
        into: %{},
        do: {String.downcase(name), description}
  end

  defp read_catalogue(key, max_age_ms) do
    case lookup(key) do
      {descriptions, taken_at_ms} when is_integer(taken_at_ms) ->
        if now_ms() - taken_at_ms <= max_age_ms, do: {:ok, descriptions, taken_at_ms}, else: :none

      _unavailable ->
        :none
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, descriptions, taken_at_ms}] -> {descriptions, taken_at_ms}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp broadcast(taken_at_ms) do
    if Process.whereis(Aiur.PubSub),
      do: Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:label_catalogue_changed, taken_at_ms})

    :ok
  end

  defp repo_key(owner, repo), do: String.downcase("#{owner}/#{repo}")

  defp now_ms, do: System.system_time(:millisecond)
end

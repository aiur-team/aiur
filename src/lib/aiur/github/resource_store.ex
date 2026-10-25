defmodule Aiur.GitHub.ResourceStore do
  @moduledoc """
  Restart-durable GitHub state keyed by **resource identity**, not by call site.

  Aiur learns the same GitHub fact through more than one pipe. A comment arrives
  free over a webhook and is then read again, at full price, by the comment poll
  sweep. `Aiur.Events.GitHubWebhook.Normalizer` already reduces a delivery to
  keys "taken one for one from `CommentPollBatch.normalize_comments/1`" so that
  consumers cannot tell the two apart — which is the proof that they are the
  same event, and therefore that one of the two reads is waste.

  This store is where the pipes meet. Every entry is addressed by
  `{resource_type, owner, repo, id}`, so a comment written by the webhook pipe
  and the same comment seen by the poll sweep resolve to one entry regardless of
  which API shape produced it. Keying by call site instead would make the entry
  unreadable from the other pipe, which is the whole point.

  ## Who writes and who reads today

  Deliberately recorded so a later unit does not assume more than exists.
  Writers: `Aiur.Events.GithubCommentsPoller` deposits each watched target's
  comment *lists* as bodies with the endpoint's validator,
  `Aiur.GitHub.Listeners.CommandScan.Scan` deposits the two repo-wide comment streams the
  same way, `Aiur.Events.GitHubWebhook.Deposit` deposits delivered issues, labels,
  pull requests and the open pull request for a ticket's head branch,
  `Aiur.GitHub.ResourceFetch` deposits what it fetches, mutation write-through
  merges its own responses, and `Aiur.Events.Publisher` marks individual comment
  resources processed. `Aiur.GitHub.CommentPollBatch` deposits the comment→thread
  mapping it parses (`:pr_review_comment_thread`), `Aiur.GitHub.DependenciesApi`
  both reads and writes the blocked-by list (`:issue_blocked_by`), whose edges
  the webhook deposit and the dependency mutation also merge in, and
  `Aiur.GitHub.PollSnapshots` converges complete review-thread and CI-context
  selections (#2326). Readers: the poller and the command scan both serve their
  own `304` from the held list, `Aiur.GitHub.Issues` and the dashboard read
  bodies, the thread resolver reads the comment→thread map, the dependencies
  reader serves the blocked-by list, and the three GraphQL poll paths consult
  delivery-fresh selection snapshots before spending.

  Design details live beside the implementation in `Cas`, `Deposit`, `Marks`,
  `Reads`, `Retention`, `Body` and `Persistence`.
  """

  use GenServer

  alias Aiur.GitHub.ResourceEvents
  alias Aiur.GitHub.ResourceStore.{Checkpoint, Collections, Deposit, Docs, Marks, Persistence, Reads, Retention, Storage, Types, Validators}

  @table __MODULE__.Table
  @sweep_interval_ms 5 * 60 * 1000
  @checkpoint_interval_ms 30 * 1000

  @type resource_type :: atom()
  @type key :: {resource_type(), String.t(), String.t(), String.t()}
  @type entry :: %{
          data: term(),
          version: String.t() | nil,
          source: atom() | nil,
          fetched_at_ms: integer() | nil,
          full_body_at_ms: integer() | nil,
          etag: String.t() | nil
        }

  # The stored entry keeps two `source` facts apart: `:source` is the pipe that
  # last marked the resource processed, `:data_source` is the pipe that
  # deposited the body. They used to be one field, so a deposit and a mark
  # overwrote each other's answer.

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc Docs.resource_types()
  @spec resource_types() :: [resource_type()]
  defdelegate resource_types(), to: Types

  @doc Docs.key()
  @spec key(resource_type(), String.t(), String.t(), term()) :: key() | nil
  defdelegate key(resource_type, owner, repo, id), to: Types

  @doc Docs.key_for_repo()
  @spec key_for_repo(resource_type(), String.t() | nil, term()) :: key() | nil
  defdelegate key_for_repo(resource_type, full_name, id), to: Types

  @doc Docs.etag()
  @spec etag(key() | nil) :: String.t() | nil
  def etag(key), do: Reads.etag(@table, key)

  @doc Docs.change_validator()
  @spec change_validator(key() | nil) :: String.t() | nil
  def change_validator(key), do: Reads.change_validator(@table, key)

  @doc Docs.put_etag()
  @spec put_etag(key() | nil, String.t() | nil, String.t() | nil | :any) :: :ok
  def put_etag(key, etag, previous \\ :any), do: Validators.put_etag(@table, key, etag, previous)

  @doc Docs.processed?()
  @spec processed?(key() | nil, String.t() | nil) :: boolean()
  def processed?(key, version \\ nil), do: Marks.processed?(@table, key, version)

  @doc Docs.unversioned_suppression_ms()
  @spec unversioned_suppression_ms() :: pos_integer()
  defdelegate unversioned_suppression_ms(), to: Marks

  @doc Docs.mark_processed()
  @spec mark_processed(key() | nil, atom(), String.t() | nil) :: :ok
  def mark_processed(key, source, version \\ nil), do: Marks.mark_processed(@table, key, source, version)

  @doc Docs.claim()
  @spec claim(key() | nil, atom(), String.t() | nil) :: :marked | :already_processed
  def claim(key, source, version \\ nil), do: Marks.claim(@table, key, source, version)

  @doc Docs.put_resource()
  @spec put_resource(key() | nil, term(), keyword()) :: :ok | {:error, term()}
  def put_resource(key, data, opts \\ []), do: Deposit.put_resource(@table, key, data, opts)

  @doc Docs.deposit_unless_older()
  @spec deposit_unless_older(key() | nil, term(), keyword()) :: :ok | {:ok, :superseded} | {:error, term()}
  def deposit_unless_older(key, data, opts \\ []), do: Deposit.deposit_unless_older(@table, key, data, opts)

  @doc Docs.regression?()
  @spec regression?(term(), term()) :: boolean()
  defdelegate regression?(held, version), to: Deposit

  @doc Docs.update_resource()
  @spec update_resource(key() | nil, (term() -> term()) | (term(), map() -> term()), keyword()) :: :ok | :unchanged
  def update_resource(key, fun, opts \\ []), do: Deposit.update_resource(@table, key, fun, opts)

  @doc Docs.revalidate()
  @spec revalidate(key() | nil, term(), String.t() | nil) :: :confirmed | :superseded | :miss
  def revalidate(key, confirmed_data, etag), do: Validators.revalidate(@table, key, confirmed_data, etag)

  @doc Docs.drop_data()
  @spec drop_data(key() | nil) :: :ok
  def drop_data(key), do: Validators.drop_data(@table, key)

  @doc Docs.drop_etag()
  @spec drop_etag(key() | nil) :: :ok
  def drop_etag(key), do: Validators.drop_etag(@table, key)

  @doc Docs.fetch()
  @spec fetch(key() | nil) :: {:ok, entry()} | :miss
  def fetch(key), do: Reads.fetch(@table, key)

  @doc Docs.data()
  @spec data(key() | nil) :: term()
  def data(key), do: Reads.data(@table, key)

  @doc Docs.clear()
  @spec clear(resource_type(), String.t(), String.t()) :: :ok
  def clear(resource_type, owner, repo), do: Collections.clear(@table, resource_type, owner, repo)

  @doc Docs.membership_snapshot()
  @spec membership_snapshot(String.t(), String.t()) :: {:ok, list()} | {:error, :unavailable}
  def membership_snapshot(owner, repo), do: Collections.membership_snapshot(@table, owner, repo)

  @doc Docs.replace_membership()
  @spec replace_membership(String.t(), String.t(), list(), list()) :: :ok | {:error, atom()}
  def replace_membership(owner, repo, expected, edges), do: Collections.replace_membership(@table, owner, repo, expected, edges)

  @doc Docs.list()
  @spec list(resource_type(), String.t(), String.t()) :: [{key(), entry()}]
  def list(resource_type, owner, repo), do: Collections.list(@table, resource_type, owner, repo)

  @doc Docs.list_type()
  @spec list_type(resource_type(), String.t() | nil) :: [{key(), term()}]
  def list_type(type, full_name), do: Reads.list_type(@table, type, full_name)

  @doc Docs.reset()
  @spec reset() :: :ok
  def reset, do: Collections.reset(@table)

  @doc false
  @spec forget(key() | nil) :: :ok
  def forget(key), do: Collections.forget(@table, key)

  @doc Docs.topic()
  @spec topic(key()) :: String.t() | nil
  defdelegate topic(key), to: ResourceEvents

  @doc Docs.type_topic()
  @spec type_topic(resource_type()) :: String.t() | nil
  defdelegate type_topic(type), to: ResourceEvents

  @doc Docs.subscribe()
  @spec subscribe(key() | resource_type() | nil) :: :ok
  defdelegate subscribe(key_or_type), to: ResourceEvents

  @doc Docs.unsubscribe()
  @spec unsubscribe(key() | resource_type() | nil) :: :ok
  defdelegate unsubscribe(key_or_type), to: ResourceEvents

  @doc Docs.subscribe_type()
  @spec subscribe_type(resource_type()) :: :ok
  def subscribe_type(type) when is_atom(type), do: ResourceEvents.subscribe(type)

  @doc Docs.subscribe_all()
  @spec subscribe_all() :: :ok
  defdelegate subscribe_all(), to: ResourceEvents

  @doc false
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush, 15_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc Docs.running?()
  @spec running?() :: boolean()
  def running?, do: Storage.with_table(@table, false, fn _table -> true end)

  @doc Docs.retention_ms()
  @spec retention_ms() :: pos_integer()
  def retention_ms, do: Retention.retention_ms()

  @doc Docs.size()
  @spec size() :: non_neg_integer()
  def size do
    Storage.with_table(@table, 0, fn table -> :ets.info(table, :size) || 0 end)
  end

  # -- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    Checkpoint.init()

    path = Persistence.resolve_path(opts)
    loaded = Persistence.load(path)

    # `insert_new/2`, not `insert/2`. The table is `:named_table` and `:public`
    # and every writer reaches it through `:ets.whereis/1`, so it is writable from
    # the instant `:ets.new/2` returns — which is before this load finishes. A
    # webhook delivery landing in that window deposits the *current* body, and a
    # blind insert of the checkpoint would replace it with whatever was on disk up
    # to 30 seconds before the restart. That is a body rollback at boot, arriving
    # through the one write path that never had a compare-and-swap.
    Enum.each(loaded, &:ets.insert_new(table, &1))

    if path, do: schedule(:checkpoint, checkpoint_interval(opts))
    schedule(:sweep, sweep_interval(opts))

    {:ok, %{table: table, path: path, last_written_revision: nil}, :hibernate}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {reply, state} = Persistence.checkpoint(state, force: true)
    {:reply, reply, state, :hibernate}
  end

  def handle_call({:membership_access, fun}, _from, state), do: {:reply, fun.(), state}

  @impl true
  def handle_info(:checkpoint, state) do
    {_reply, state} = Persistence.checkpoint(state)
    schedule(:checkpoint, @checkpoint_interval_ms)
    {:noreply, state, :hibernate}
  end

  def handle_info(:sweep, state) do
    Retention.sweep(state.table)
    schedule(:sweep, @sweep_interval_ms)
    {:noreply, state, :hibernate}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Persistence.checkpoint(state, force: true)
    :ok
  end

  # -- internals ------------------------------------------------------------

  defp sweep_interval(opts), do: Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
  defp checkpoint_interval(opts), do: Keyword.get(opts, :checkpoint_interval_ms, @checkpoint_interval_ms)

  defp schedule(message, interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), message, interval)
  end

  defp schedule(_message, _interval), do: :ok
end

defmodule Aiur.Webhooks.ModeTable do
  @moduledoc """
  The per-repo delivery-mode view a hot read path can consult without a process
  hop.

  `Aiur.GitHub.ReadCache.Policy` decides a cacheable read's TTL from the
  repository's delivery mode: a proven webhook-backed repo earns a long TTL
  because every mutation path is covered by a delivery, and a polling repo
  (never configured, configured-but-unproven, or degraded from silence) keeps
  the short TTL as its freshness mechanism. That decision runs on **every**
  cacheable GitHub request, so it cannot be a `ModeRegistry` round trip —
  `IntervalPolicy` can afford one on the poll cadence, but the cache hit path
  exists to be shorter, not to wait on a mailbox that may be servicing a
  sweep.

  The delivery mode and config-event coverage live in two ETS tables. The
  registry publishes mode changes, and the verified receiver records each
  event family it has observed. Repository-config reads get the long TTL only
  after both `branch_protection_rule` and `repository_ruleset` have arrived;
  when a repo returns to polling, that evidence is cleared. The policy reads
  both tables without a process hop. Reads run in the request process, exactly
  like `ReadCache`'s own tables.

  ## Failing safe

  Reads answer `:polling` whenever the table is absent — no registry booted, a
  CLI process, a restart in flight. A repo with no recorded mode is a repo
  whose webhook is unproven, which is the conservative answer and today's
  behavior. A missing mode can only ever cost points, never correctness.
  """

  use GenServer

  alias Aiur.Webhooks.DeliveryMode

  @table :aiur_webhook_delivery_modes
  @config_events_table :aiur_webhook_repo_config_events
  @config_events ~w(push branch_protection_rule repository_ruleset repository)
  @config_ttl_events ~w(branch_protection_rule repository_ruleset)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)

    :ets.new(table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    if table == @table do
      :ets.new(@config_events_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Records the current mode for `repo`.

  Called by `Aiur.Webhooks.ModeRegistry` on every mode change and by tests that
  want to exercise the TTL decision directly. Idempotent: a later record
  replaces the earlier one. No-op when no table is running.
  """
  @spec put(String.t(), DeliveryMode.t()) :: :ok
  def put(repo, %DeliveryMode{} = mode) do
    with_table(:ok, fn table ->
      normalized_repo = normalize(repo)
      :ets.insert(table, {normalized_repo, mode})

      if DeliveryMode.transport(mode) == :polling do
        delete_config_events(repo)
      end
    end)
  end

  @doc "Records a verified delivery family that can retire repository configuration."
  @spec record_config_event(String.t(), String.t()) :: :ok
  def record_config_event(repo, event) when event in @config_events do
    with_table(
      :ok,
      fn table -> :ets.insert(table, {{normalize(repo), event}, true}) end,
      @config_events_table
    )
  end

  def record_config_event(_repo, _event), do: :ok

  @doc "Whether both required repository-config rule event families were observed."
  @spec config_events?(String.t()) :: boolean()
  def config_events?(repo) do
    with_table(
      false,
      fn table ->
        normalized_repo = normalize(repo)
        Enum.all?(@config_ttl_events, &:ets.member(table, {normalized_repo, &1}))
      end,
      @config_events_table
    )
  end

  @doc "The effective webhook transport for repository configuration reads."
  @spec repo_config_transport(String.t(), DeliveryMode.transport()) :: DeliveryMode.transport()
  def repo_config_transport(repo, :webhook) do
    if config_events?(repo), do: :webhook, else: :polling
  end

  def repo_config_transport(_repo, transport), do: transport

  @doc "Removes observed config-event coverage for `repo`. Test seam."
  @spec delete_config_events(String.t()) :: :ok
  def delete_config_events(repo) do
    with_table(
      :ok,
      fn table ->
        normalized_repo = normalize(repo)
        Enum.each(@config_events, &:ets.delete(table, {normalized_repo, &1}))
      end,
      @config_events_table
    )
  end

  @doc """
  The transport currently serving `repo`.

  Answers `:polling` for a repo the table knows nothing about, or when no table
  is running — the conservative reading that keeps the short TTL.
  """
  @spec transport(String.t()) :: DeliveryMode.transport()
  def transport(repo) do
    case mode(repo) do
      nil -> :polling
      mode -> DeliveryMode.transport(mode)
    end
  end

  @doc "Returns the full recorded delivery mode, or nil when unrecorded or not running."
  @spec mode(String.t()) :: DeliveryMode.t() | nil
  def mode(repo) do
    with_table(nil, fn table ->
      case :ets.lookup(table, normalize(repo)) do
        [{_repo, mode}] -> mode
        _unrecorded -> nil
      end
    end)
  end

  @doc "Removes the recorded mode for `repo`. Test seam."
  @spec delete(String.t()) :: :ok
  def delete(repo) do
    with_table(:ok, fn table -> :ets.delete(table, normalize(repo)) end)
  end

  # Repository names are case-insensitive, and the two pipes that feed mode
  # disagree on case exactly as they do everywhere else in this subsystem. The
  # key is normalized the same way `ModeRegistry` normalizes its repo keys, so a
  # delivery-cased publish and a config-cased read resolve to one entry.
  defp normalize(repo) when is_binary(repo), do: repo |> String.trim() |> String.downcase()
  defp normalize(_repo), do: ""

  defp with_table(fallback, fun, table_name \\ @table) do
    case :ets.whereis(table_name) do
      :undefined -> fallback
      table -> fun.(table)
    end
  rescue
    ArgumentError -> fallback
  end
end

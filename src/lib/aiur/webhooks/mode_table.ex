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

  This table is where `ModeRegistry` publishes the current mode of every repo
  it knows, and where the policy reads it back. Writes land in ETS from the
  registry's own process; reads land in ETS from the request's process, exactly
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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
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
    with_table(:ok, fn table -> :ets.insert(table, {normalize(repo), mode}) end)
  end

  @doc """
  The transport currently serving `repo`.

  Answers `:polling` for a repo the table knows nothing about, or when no table
  is running — the conservative reading that keeps the short TTL.
  """
  @spec transport(String.t()) :: DeliveryMode.transport()
  def transport(repo) do
    with_table(:polling, fn table ->
      case :ets.lookup(table, normalize(repo)) do
        [{_repo, mode}] -> DeliveryMode.transport(mode)
        _unrecorded -> :polling
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

  defp with_table(fallback, fun) do
    case :ets.whereis(@table) do
      :undefined -> fallback
      table -> fun.(table)
    end
  rescue
    ArgumentError -> fallback
  end
end

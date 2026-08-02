defmodule Aiur.UsageLedger do
  @moduledoc """
  Stable daemon-owned seam for canonical raw usage accounting.

  The configured backend is the single writer for accepted envelopes. An
  acknowledgement is returned only after that backend has made both the raw
  record and its counter/idempotency checkpoint durable.
  """

  use Supervisor

  alias Aiur.UsageEnvelope

  @backend_key {__MODULE__, :backend}

  @type acknowledgement :: %{
          required(:position) => pos_integer(),
          required(:generation) => pos_integer(),
          required(:delta) => map()
        }

  @type replay_record :: %{
          required(:position) => pos_integer(),
          required(:generation) => pos_integer(),
          required(:envelope) => UsageEnvelope.t(),
          required(:delta) => map(),
          required(:source_version) => String.t(),
          required(:relationship_revision) => String.t(),
          required(:coverage_reasons) => [atom()]
        }

  @type health :: :healthy | {:degraded, atom()} | {:unavailable, atom()}

  @type retirement :: %{
          required(:retired_through) => non_neg_integer(),
          required(:retired_count) => non_neg_integer()
        }

  @callback append(UsageEnvelope.t()) :: {:ok, acknowledgement()} | {:duplicate, acknowledgement()} | {:error, atom()}
  @callback scan(keyword()) :: {:ok, [replay_record()]} | {:error, atom()}
  @callback retire(non_neg_integer()) :: {:ok, retirement()} | {:error, atom()}
  @callback health() :: health()
  @callback generation() :: non_neg_integer()
  @callback coverage() :: map()
  @callback subscribe(pid()) :: :ok
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    backend = configured_backend()
    :persistent_term.put(@backend_key, backend)

    child =
      backend
      |> Supervisor.child_spec(opts)
      |> Map.put(:id, backend)

    Supervisor.init([child], strategy: :one_for_one)
  end

  @doc """
  Appends through the configured backend. The file-backed store is the
  default; tests and future migrations may substitute another behavior
  implementation without introducing a second live writer.
  """
  @spec append(UsageEnvelope.t()) :: {:ok, acknowledgement()} | {:duplicate, acknowledgement()} | {:error, atom()}
  def append(%UsageEnvelope{} = envelope), do: backend().append(envelope)

  @spec scan(keyword()) :: {:ok, [replay_record()]} | {:error, atom()}
  def scan(options \\ []) when is_list(options), do: backend().scan(options)

  @doc """
  Retires every raw record at or below `watermark`, reclaiming its storage after
  DASH-025 has committed durable dimension-preserving aggregate coverage for the
  range. The watermark is the highest retired position; retirement is idempotent
  and never crosses the current ledger head. The durable retained counter state
  is unchanged, so exact totals and coverage are preserved — only the raw source
  for the already-covered prefix is removed.
  """
  @spec retire(non_neg_integer()) :: {:ok, retirement()} | {:error, atom()}
  def retire(watermark) when is_integer(watermark) and watermark >= 0, do: backend().retire(watermark)

  @spec health() :: health()
  def health, do: backend().health()

  @spec generation() :: non_neg_integer()
  def generation, do: backend().generation()

  @spec coverage() :: map()
  def coverage, do: backend().coverage()

  @doc """
  Registers for post-acknowledgement position-bearing refreshes.

  Consumers subscribe first, then scan from their persisted position and
  deduplicate refreshes by position. This ordered cursor protocol prevents a
  scan-to-subscribe gap without exposing raw files.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) when is_pid(pid), do: backend().subscribe(pid)

  defp backend do
    if Process.whereis(__MODULE__),
      do: :persistent_term.get(@backend_key),
      else: configured_backend()
  end

  defp configured_backend, do: Application.get_env(:aiur, :usage_ledger_backend, Aiur.UsageLedger.Store)
end

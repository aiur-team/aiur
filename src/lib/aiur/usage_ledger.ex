defmodule Aiur.UsageLedger do
  @moduledoc """
  Stable daemon-owned seam for canonical raw usage accounting.

  The configured backend is the single writer for accepted envelopes. An
  acknowledgement is returned only after that backend has made both the raw
  record and its counter/idempotency checkpoint durable.
  """

  alias Aiur.UsageEnvelope

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

  @callback append(UsageEnvelope.t()) :: {:ok, acknowledgement()} | {:duplicate, acknowledgement()} | {:error, atom()}
  @callback scan(keyword()) :: {:ok, [replay_record()]} | {:error, atom()}
  @callback health() :: health()
  @callback generation() :: non_neg_integer()
  @callback coverage() :: map()
  @callback subscribe(pid()) :: :ok

  @doc """
  Appends through the configured backend. The file-backed store is the
  default; tests and future migrations may substitute another behavior
  implementation without introducing a second live writer.
  """
  @spec append(UsageEnvelope.t()) :: {:ok, acknowledgement()} | {:duplicate, acknowledgement()} | {:error, atom()}
  def append(%UsageEnvelope{} = envelope), do: backend().append(envelope)

  @spec append(UsageEnvelope.t(), GenServer.server()) :: {:ok, acknowledgement()} | {:duplicate, acknowledgement()} | {:error, atom()}
  def append(%UsageEnvelope{} = envelope, server), do: GenServer.call(server, {:append, envelope})

  @spec scan(keyword()) :: {:ok, [replay_record()]} | {:error, atom()}
  def scan(options \\ []) when is_list(options), do: backend().scan(options)

  @spec scan(keyword(), GenServer.server()) :: {:ok, [replay_record()]} | {:error, atom()}
  def scan(options, server) when is_list(options), do: GenServer.call(server, {:scan, options})

  @spec health() :: health()
  def health, do: backend().health()

  @spec health(GenServer.server()) :: health()
  def health(server), do: GenServer.call(server, :health)

  @spec generation() :: non_neg_integer()
  def generation, do: backend().generation()

  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server), do: GenServer.call(server, :generation)

  @spec coverage() :: map()
  def coverage, do: backend().coverage()

  @spec coverage(GenServer.server()) :: map()
  def coverage(server), do: GenServer.call(server, :coverage)

  @doc """
  Registers for post-acknowledgement position-bearing refreshes.

  Consumers subscribe first, then scan from their persisted position and
  deduplicate refreshes by position. This ordered cursor protocol prevents a
  scan-to-subscribe gap without exposing raw files.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) when is_pid(pid), do: backend().subscribe(pid)

  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(pid, server) when is_pid(pid), do: GenServer.call(server, {:subscribe, pid})

  defp backend, do: Application.get_env(:aiur, :usage_ledger_backend, Aiur.UsageLedger.Store)
end

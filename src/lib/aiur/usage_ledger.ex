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
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Supervisor.child_spec(backend(), opts)

  @doc """
  Appends through the configured backend. The file-backed store is the
  default; tests and future migrations may substitute another behavior
  implementation without introducing a second live writer.
  """
  @spec append(UsageEnvelope.t()) :: {:ok, acknowledgement()} | {:duplicate, acknowledgement()} | {:error, atom()}
  def append(%UsageEnvelope{} = envelope), do: backend().append(envelope)

  @spec scan(keyword()) :: {:ok, [replay_record()]} | {:error, atom()}
  def scan(options \\ []) when is_list(options), do: backend().scan(options)

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

  defp backend, do: Application.get_env(:aiur, :usage_ledger_backend, Aiur.UsageLedger.Store)
end

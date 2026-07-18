defmodule Aiur.Usage.Headless.Context do
  @moduledoc """
  Trusted, content-free runtime context consumed by headless usage adapters.

  The context carries only attribution and account-generation facts already
  ordered by DASH-008's prerequisites (BO-017 identity propagation and the
  DASH-018 shared account generation). It never carries prompts, provider
  bodies, credentials, or local paths. Missing attribution stays missing: it is
  never recovered from prose or paths, and never becomes a guessed identity.
  """

  alias Aiur.{Boot, Issue, TrackerIdentity}
  alias Aiur.ProviderAccountGeneration.Snapshot

  @enforce_keys [:run_id, :agent_family, :backend, :transport, :account_generation, :source_sequence]
  defstruct [
    :run_id,
    :tracker_identity,
    :attempt_id,
    :session_id,
    :thread_id,
    :turn_id,
    :request_id,
    :worker_generation,
    :agent_family,
    :backend,
    :transport,
    :requested_model,
    :resolved_model,
    :effort,
    :query_source,
    :account_generation,
    :source_sequence,
    :observed_source_version,
    auth_mode: :unknown
  ]

  @type account_generation :: %{
          provider: :codex | :claude,
          backend: :app_server,
          generation: String.t() | nil,
          freshness: :current | :unknown,
          health: :healthy | :unknown | :unavailable,
          reason: atom() | nil
        }

  @type t :: %__MODULE__{}

  @agent_families %{"codex" => :codex, "claude" => :claude}

  @doc """
  Builds a context for one headless message at the MessageHandler seam.

  Returns `:unsupported` for any backend that is not a supported headless
  provider (for example Remote Control or REPL transports owned elsewhere).
  """
  @spec build(Issue.t() | nil, String.t(), keyword()) :: {:ok, t()} | :unsupported
  def build(issue, backend, opts) when is_binary(backend) and is_list(opts) do
    case Map.get(@agent_families, backend) do
      nil -> :unsupported
      agent_family -> {:ok, assemble(issue, agent_family, opts)}
    end
  end

  def build(_issue, _backend, _opts), do: :unsupported

  defp assemble(issue, agent_family, opts) do
    generation = account_generation(agent_family, opts)

    %__MODULE__{
      run_id: Keyword.get(opts, :run_id) || Boot.run_id(),
      tracker_identity: tracker_identity(issue),
      attempt_id: string_or_nil(Keyword.get(opts, :attempt_id) || Keyword.get(opts, :telemetry_attempt_id)),
      session_id: string_or_nil(Keyword.get(opts, :session_id)),
      thread_id: string_or_nil(Keyword.get(opts, :thread_id)),
      turn_id: string_or_nil(Keyword.get(opts, :turn_id)),
      request_id: string_or_nil(Keyword.get(opts, :request_id)),
      worker_generation: Keyword.get(opts, :worker_generation),
      agent_family: agent_family,
      backend: :app_server,
      transport: :app_server,
      auth_mode: auth_mode(opts),
      requested_model: string_or_nil(Keyword.get(opts, :requested_model)),
      resolved_model: string_or_nil(Keyword.get(opts, :resolved_model)),
      effort: string_or_nil(Keyword.get(opts, :effort)),
      query_source: string_or_nil(Keyword.get(opts, :query_source)),
      account_generation: generation,
      source_sequence: source_sequence(opts),
      observed_source_version: string_or_nil(Keyword.get(opts, :observed_source_version))
    }
  end

  defp tracker_identity(issue) do
    case Issue.tracker_identity(issue) do
      %TrackerIdentity{} = identity -> if TrackerIdentity.joinable?(identity), do: identity
      _missing -> nil
    end
  end

  # A trusted DASH-018 snapshot may be supplied through opts; otherwise the
  # owner-resolved generation is unavailable at this seam and the envelope
  # records bounded coverage rather than borrowing another account's identity.
  defp account_generation(agent_family, opts) do
    opts
    |> Keyword.get(:account_generation, Snapshot.unavailable(agent_family, :app_server))
    |> project_generation(agent_family)
  end

  @doc "Projects a DASH-018 account-generation snapshot into the envelope's account context."
  @spec project_generation(map(), :codex | :claude) :: account_generation()
  def project_generation(%{generation: generation, freshness: freshness, health: health, reason: reason}, agent_family) do
    %{
      provider: agent_family,
      backend: :app_server,
      generation: string_or_nil(generation),
      freshness: freshness,
      health: health,
      reason: reason
    }
  end

  def project_generation(_snapshot, agent_family) do
    project_generation(Snapshot.unavailable(agent_family, :app_server), agent_family)
  end

  defp auth_mode(opts) do
    case Keyword.get(opts, :auth_mode) do
      mode when mode in [:api_key, :chatgpt, :unknown] -> mode
      _other -> :unknown
    end
  end

  defp source_sequence(opts) do
    case Keyword.get(opts, :source_sequence) do
      sequence when is_integer(sequence) and sequence >= 0 -> sequence
      _missing -> System.unique_integer([:monotonic, :positive])
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_value), do: nil
end

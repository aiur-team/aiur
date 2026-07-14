defmodule Aiur.DecisionProvenance do
  @moduledoc """
  Versioned, trusted runtime facts captured when a Decision is accepted.

  This value intentionally retains only an allowlisted set of scalar runtime
  identities. It never accepts an agent payload, account identity, prompt,
  transcript, raw session map, credential, environment value, or capability
  URL.
  """

  alias Aiur.SecretRedactor

  @schema_version 1
  @identity_max 256
  @source "agent_runner"
  @allowed_fields ~w(agent_family attempt_id backend requested_model resolved_model session_id source)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          agent_family: String.t() | nil,
          backend: String.t() | nil,
          requested_model: String.t() | nil,
          resolved_model: String.t() | nil,
          session_id: String.t() | nil,
          attempt_id: String.t() | nil,
          source: String.t(),
          captured_at: DateTime.t()
        }

  @enforce_keys [:source, :captured_at]
  defstruct @enforce_keys ++
              [
                schema_version: @schema_version,
                agent_family: nil,
                backend: nil,
                requested_model: nil,
                resolved_model: nil,
                session_id: nil,
                attempt_id: nil
              ]

  @doc "Current schema version written for newly captured provenance."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Normalizes a trusted runtime allowlist or leaves unknown provenance absent."
  @spec normalize(map() | nil, DateTime.t()) :: {:ok, t() | nil} | {:error, term()}
  def normalize(nil, %DateTime{}), do: {:ok, nil}

  def normalize(%__MODULE__{} = provenance, %DateTime{}) do
    provenance |> to_json_safe() |> from_json_safe()
  end

  def normalize(runtime, %DateTime{} = captured_at) when is_map(runtime) do
    with {:ok, runtime} <- normalize_keys(runtime),
         :ok <- validate_exact_fields(runtime),
         {:ok, source} <- source(Map.get(runtime, "source")),
         {:ok, agent_family} <- optional_identity(Map.get(runtime, "agent_family"), :agent_family),
         {:ok, backend} <- optional_identity(Map.get(runtime, "backend"), :backend),
         {:ok, requested_model} <- optional_identity(Map.get(runtime, "requested_model"), :requested_model),
         {:ok, resolved_model} <- optional_identity(Map.get(runtime, "resolved_model"), :resolved_model),
         {:ok, session_id} <- optional_identity(Map.get(runtime, "session_id"), :session_id),
         {:ok, attempt_id} <- optional_identity(Map.get(runtime, "attempt_id"), :attempt_id) do
      {:ok,
       %__MODULE__{
         agent_family: agent_family,
         backend: backend,
         requested_model: requested_model,
         resolved_model: resolved_model,
         session_id: session_id,
         attempt_id: attempt_id,
         source: source,
         captured_at: captured_at
       }}
    end
  end

  def normalize(_runtime, _captured_at), do: {:error, {:provenance, :invalid_type}}

  @doc "Decodes and validates a JSON-safe persisted provenance value."
  @spec from_json_safe(map()) :: {:ok, t()} | {:error, term()}
  def from_json_safe(raw) when is_map(raw) do
    with {:ok, schema_version} <- fetch_schema_version(raw),
         true <- schema_version == @schema_version,
         {:ok, captured_at} <- fetch_captured_at(raw),
         runtime <- Map.drop(raw, ["schema_version", :schema_version, "captured_at", :captured_at]),
         {:ok, provenance} <- normalize(runtime, captured_at) do
      {:ok, provenance}
    else
      false -> {:error, {:provenance, :unsupported_schema_version}}
      {:error, _reason} = error -> error
    end
  end

  def from_json_safe(_raw), do: {:error, {:provenance, :invalid_type}}

  @doc "JSON-safe durable representation, omitting unavailable optional facts."
  @spec to_json_safe(t()) :: map()
  def to_json_safe(%__MODULE__{} = provenance) do
    %{
      "schema_version" => provenance.schema_version,
      "source" => provenance.source,
      "captured_at" => DateTime.to_iso8601(provenance.captured_at)
    }
    |> maybe_put("agent_family", provenance.agent_family)
    |> maybe_put("backend", provenance.backend)
    |> maybe_put("requested_model", provenance.requested_model)
    |> maybe_put("resolved_model", provenance.resolved_model)
    |> maybe_put("session_id", provenance.session_id)
    |> maybe_put("attempt_id", provenance.attempt_id)
  end

  defp validate_exact_fields(runtime) do
    unknown = runtime |> Map.keys() |> Kernel.--(@allowed_fields) |> Enum.sort()

    case unknown do
      [] -> :ok
      _unknown -> {:error, {:provenance, {:unknown_fields, unknown}}}
    end
  end

  defp source(@source), do: {:ok, @source}
  defp source(_source), do: {:error, {:provenance, {:source, :invalid}}}

  defp optional_identity(nil, _field), do: {:ok, nil}

  defp optional_identity(value, field) when is_binary(value) do
    cond do
      byte_size(value) > @identity_max -> {:error, {:provenance, {field, :too_long}}}
      SecretRedactor.redact(value) != value -> {:error, {:provenance, {field, :redacted_secret}}}
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value) -> {:ok, value}
      true -> {:error, {:provenance, {field, :invalid_format}}}
    end
  end

  defp optional_identity(_value, field), do: {:error, {:provenance, {field, :invalid_type}}}

  defp fetch_schema_version(raw) do
    case Map.get(raw, "schema_version", Map.get(raw, :schema_version)) do
      version when is_integer(version) and version > 0 -> {:ok, version}
      _other -> {:error, {:provenance, {:schema_version, :missing_or_invalid}}}
    end
  end

  defp fetch_captured_at(raw) do
    case Map.get(raw, "captured_at", Map.get(raw, :captured_at)) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, captured_at, _offset} -> {:ok, captured_at}
          _other -> {:error, {:provenance, {:captured_at, :invalid}}}
        end

      _other ->
        {:error, {:provenance, {:captured_at, :missing_or_invalid}}}
    end
  end

  defp normalize_keys(runtime) do
    Enum.reduce_while(runtime, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(raw_key),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        true -> {:halt, {:error, {:provenance, {:duplicate_fields, [to_string(raw_key)]}}}}
        :error -> {:halt, {:error, {:provenance, {:field, :invalid}}}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

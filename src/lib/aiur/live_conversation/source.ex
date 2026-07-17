defmodule Aiur.LiveConversation.Source do
  @moduledoc false

  alias Aiur.{Boot, OpaqueIdentifier, TrackerIdentity}

  @field_limit 256

  @type input :: %{
          required(:identity) => TrackerIdentity.t(),
          required(:attempt_id) => String.t() | integer(),
          required(:backend) => String.t(),
          required(:worker_generation) => pos_integer(),
          optional(:run_id) => String.t(),
          optional(:session_id) => String.t() | nil
        }

  @type public :: %{
          required(:identity) => map(),
          required(:run_id) => String.t(),
          required(:attempt_id) => String.t(),
          required(:session_id) => String.t() | nil,
          required(:backend) => String.t(),
          required(:worker_generation) => pos_integer()
        }

  @type identity_key :: {:github, String.t(), String.t(), String.t()}
  @type key ::
          {identity_key(), String.t(), String.t(), String.t() | nil, String.t(), pos_integer()}

  @spec canonical(term()) :: {:ok, key(), public()} | {:error, atom()}
  def canonical(
        %{
          identity: identity,
          attempt_id: attempt_id,
          backend: backend,
          worker_generation: generation
        } = source
      )
      when (is_binary(attempt_id) or is_integer(attempt_id)) and is_binary(backend) and
             backend != "" and is_integer(generation) and generation > 0 do
    with {:github, _owner, _repository, _provider_id} = identity_key <-
           TrackerIdentity.github_key(identity),
         run_id when is_binary(run_id) <- Map.get(source, :run_id, Boot.run_id()),
         attempt_id <- to_string(attempt_id),
         session_id <- Map.get(source, :session_id),
         true <- valid_identity?(identity),
         true <- valid_required_fields?([run_id, attempt_id, backend]),
         true <- valid_optional_field?(session_id) do
      public = %{
        identity: Map.take(identity, [:version, :kind, :owner, :repository, :identifier]),
        run_id: run_id,
        attempt_id: attempt_id,
        session_id: opaque_session_id(session_id),
        backend: backend,
        worker_generation: generation
      }

      {:ok, {identity_key, run_id, attempt_id, session_id, backend, generation}, public}
    else
      nil -> {:error, :invalid_identity}
      false -> {:error, :invalid_source}
      _ -> {:error, :invalid_source}
    end
  end

  def canonical(_source), do: {:error, :invalid_source}

  @spec opaque_session_id(term()) :: String.t() | nil
  def opaque_session_id(nil), do: nil
  def opaque_session_id(session_id), do: opaque_id("session:", session_id)

  @spec valid_handle?(term()) :: boolean()
  def valid_handle?("conversation:" <> digest) do
    byte_size(digest) == 43 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, digest)
  end

  def valid_handle?(_handle), do: false

  @spec opaque_id(String.t(), term()) :: String.t()
  def opaque_id(prefix, value) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(value))
      |> Base.url_encode64(padding: false)

    prefix <> digest
  end

  defp valid_identity?(%TrackerIdentity{} = identity) do
    identity
    |> Map.take([:owner, :repository, :identifier])
    |> Map.values()
    |> valid_required_fields?()
  end

  defp valid_identity?(_identity), do: false

  defp valid_required_fields?(fields), do: Enum.all?(fields, &valid_field?/1)
  defp valid_optional_field?(nil), do: true
  defp valid_optional_field?(value), do: valid_field?(value)
  defp valid_field?(value), do: not is_nil(OpaqueIdentifier.normalize(value, @field_limit))
end

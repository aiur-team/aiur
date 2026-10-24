defmodule Aiur.ModelAvailability.AuthHold do
  @moduledoc "Durable provider authentication holds keyed by credential fingerprint."

  alias Aiur.ModelAvailability

  @spec mark_rejected(String.t(), String.t(), keyword()) :: {:ok, :first | :already_held} | {:error, term()}
  def mark_rejected(backend, fingerprint, opts \\ []) when is_binary(backend) and is_binary(fingerprint) do
    backend = ModelAvailability.backend_key(backend)
    path = Keyword.get(opts, :path, ModelAvailability.path())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    :global.trans({ModelAvailability, path}, fn ->
      state = ModelAvailability.load(path)
      backends = Map.get(state, "backends", %{})
      entry = Map.get(backends, backend, %{})
      first? = Map.get(entry, "auth_rejected") != true

      updated =
        entry
        |> Map.put("auth_rejected", true)
        |> Map.put("auth_fingerprint", fingerprint)
        |> Map.put("auth_rejected_at", DateTime.to_iso8601(now))

      case write(path, Map.put(state, "backends", Map.put(backends, backend, updated))) do
        :ok -> {:ok, if(first?, do: :first, else: :already_held)}
        error -> error
      end
    end)
  end

  @spec clear_changed(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def clear_changed(backend, fingerprint, opts \\ []) when is_binary(backend) do
    backend = ModelAvailability.backend_key(backend)
    path = Keyword.get(opts, :path, ModelAvailability.path())

    :global.trans({ModelAvailability, path}, fn ->
      state = ModelAvailability.load(path)
      backends = Map.get(state, "backends", %{})
      entry = Map.get(backends, backend, %{})

      if entry["auth_rejected"] == true and is_binary(fingerprint) and fingerprint != entry["auth_fingerprint"] do
        updated = Map.drop(entry, ["auth_rejected", "auth_fingerprint", "auth_rejected_at"])
        write(path, Map.put(state, "backends", Map.put(backends, backend, updated)))
      else
        :ok
      end
    end)
  end

  @spec rejected?(String.t(), keyword()) :: boolean()
  def rejected?(backend, opts \\ []) when is_binary(backend) do
    backend = ModelAvailability.backend_key(backend)
    state = Keyword.get_lazy(opts, :state, fn -> ModelAvailability.load(Keyword.get_lazy(opts, :path, &ModelAvailability.path/0)) end)
    get_in(state, ["backends", backend, "auth_rejected"]) == true
  end

  defp write(path, state) do
    File.mkdir_p(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    case File.write(tmp, Jason.encode!(state, pretty: true) <> "\n") do
      :ok -> File.rename(tmp, path)
      {:error, _reason} = error -> error
    end
  end
end

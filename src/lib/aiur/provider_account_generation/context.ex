defmodule Aiur.ProviderAccountGeneration.Context do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration
  alias Aiur.ProviderAccountGeneration.Continuity

  @spec new_binding(
          ProviderAccountGeneration.provider(),
          ProviderAccountGeneration.backend(),
          GenServer.server()
        ) :: map()
  def new_binding(provider, backend, server) do
    binding = issue_binding(server, provider, backend)
    context = make_ref()
    Process.put(context_key(context), binding)
    Process.put(server_key(context), server)
    Map.put(binding, :context, context)
  end

  @spec fetch(map()) ::
          {:ok, GenServer.server(), reference(), reference(), String.t()} | :error
  def fetch(%{account_generation_context: context} = session) when is_reference(context) do
    case current(context) do
      {:ok, %{binding: binding, authority: authority, topic: topic}} ->
        server =
          Map.get(
            session,
            :account_generation_server,
            Process.get(server_key(context), ProviderAccountGeneration)
          )

        {:ok, server, binding, authority, topic}

      :error ->
        :error
    end
  end

  def fetch(_session), do: :error

  @spec value(map(), atom()) :: term() | nil
  def value(%{account_generation_context: context}, key)
      when is_reference(context) and is_atom(key) do
    case current(context) do
      {:ok, retained} -> Map.get(retained, key)
      :error -> nil
    end
  end

  def value(_session, _key), do: nil

  @spec put(map(), atom(), term()) :: :ok
  def put(%{account_generation_context: context}, key, value)
      when is_reference(context) and is_atom(key) do
    case current(context) do
      {:ok, retained} -> Process.put(context_key(context), Map.put(retained, key, value))
      :error -> :ok
    end

    :ok
  end

  def put(_session, _key, _value), do: :ok

  @spec delete(map(), atom()) :: :ok
  def delete(%{account_generation_context: context}, key)
      when is_reference(context) and is_atom(key) do
    case current(context) do
      {:ok, retained} -> Process.put(context_key(context), Map.delete(retained, key))
      :error -> :ok
    end

    :ok
  end

  def delete(_session, _key), do: :ok

  @spec clear(
          ProviderAccountGeneration.provider(),
          ProviderAccountGeneration.backend(),
          map()
        ) :: :ok
  def clear(provider, backend, %{account_generation_context: context})
      when is_reference(context) do
    forget_continuity(provider, backend, context)
    Process.put(context_key(context), :cleared)
    Process.delete(server_key(context))
    :ok
  end

  def clear(_provider, _backend, _session), do: :ok

  defp issue_binding(server, provider, backend) do
    case ProviderAccountGeneration.issue_binding(server, provider, backend) do
      {:ok, binding} -> binding
      {:error, _reason} -> Continuity.issue(server, provider, backend)
    end
  end

  defp current(context) do
    case Process.get(context_key(context)) do
      %{binding: binding, authority: authority, topic: topic} = retained
      when is_reference(binding) and is_reference(authority) and is_binary(topic) ->
        {:ok, retained}

      _ ->
        :error
    end
  end

  defp forget_continuity(provider, backend, context) do
    with {:ok, %{binding: binding}} <- current(context),
         server <- Process.get(server_key(context), ProviderAccountGeneration) do
      Continuity.forget(Continuity.service_id(server), {provider, backend, binding})
    end
  end

  defp context_key(context),
    do: {__MODULE__, :binding_context, context}

  defp server_key(context),
    do: {__MODULE__, :binding_context_server, context}
end

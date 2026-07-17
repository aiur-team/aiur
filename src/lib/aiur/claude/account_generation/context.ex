defmodule Aiur.Claude.AccountGeneration.Context do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration
  alias Aiur.ProviderAccountGeneration.Continuity

  @spec new_binding(GenServer.server()) :: map()
  def new_binding(server) do
    binding =
      case ProviderAccountGeneration.issue_binding(server, :claude, :app_server) do
        {:ok, binding} -> binding
        {:error, _reason} -> Continuity.issue(server, :claude, :app_server)
      end

    context = make_ref()
    Process.put(context_key(context), binding)
    Process.put(server_key(context), server)
    Map.put(binding, :context, context)
  end

  @spec fetch(map()) :: {:ok, GenServer.server(), reference(), reference(), String.t()} | :error
  def fetch(%{account_generation_context: context} = session) when is_reference(context) do
    case current(context) do
      {:ok, %{binding: binding, authority: authority, topic: topic}} ->
        {:ok, Map.get(session, :account_generation_server, ProviderAccountGeneration), binding, authority, topic}

      :error ->
        :error
    end
  end

  def fetch(_session), do: :error

  @spec auth_mode(map()) :: :subscription | :api_key | nil
  def auth_mode(%{account_generation_context: context}) when is_reference(context) do
    case current(context) do
      {:ok, binding} -> Map.get(binding, :auth_mode)
      :error -> nil
    end
  end

  def auth_mode(_session), do: nil

  @spec put_auth_mode(map(), :subscription | :api_key) :: :ok
  def put_auth_mode(%{account_generation_context: context}, auth_mode)
      when is_reference(context) and auth_mode in [:subscription, :api_key] do
    case current(context) do
      {:ok, binding} -> Process.put(context_key(context), Map.put(binding, :auth_mode, auth_mode))
      :error -> :ok
    end

    :ok
  end

  def put_auth_mode(_session, _auth_mode), do: :ok

  @spec clear_auth_mode(map()) :: :ok
  def clear_auth_mode(%{account_generation_context: context}) when is_reference(context) do
    case current(context) do
      {:ok, binding} -> Process.put(context_key(context), Map.delete(binding, :auth_mode))
      :error -> :ok
    end

    :ok
  end

  def clear_auth_mode(_session), do: :ok

  @spec clear(map()) :: :ok
  def clear(%{account_generation_context: context}) when is_reference(context) do
    forget_continuity(context)
    Process.put(context_key(context), :cleared)
    :ok
  end

  def clear(_session), do: :ok

  defp current(context) do
    case Process.get(context_key(context)) do
      %{binding: binding, authority: authority, topic: topic} = retained
      when is_reference(binding) and is_reference(authority) and is_binary(topic) ->
        {:ok,
         %{
           binding: binding,
           authority: authority,
           topic: topic,
           auth_mode: Map.get(retained, :auth_mode)
         }}

      _ ->
        :error
    end
  end

  defp forget_continuity(context) do
    with {:ok, %{binding: binding}} <- current(context),
         server <- Process.get(server_key(context), ProviderAccountGeneration) do
      Continuity.forget(Continuity.service_id(server), {:claude, :app_server, binding})
    end
  end

  defp context_key(context), do: {Aiur.Claude.AccountGeneration, :binding_context, context}
  defp server_key(context), do: {Aiur.Claude.AccountGeneration, :binding_context_server, context}
end

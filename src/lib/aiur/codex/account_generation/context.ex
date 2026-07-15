defmodule Aiur.Codex.AccountGeneration.Context do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration
  alias Aiur.ProviderAccountGeneration.Continuity

  @spec new_binding(GenServer.server()) :: map()
  def new_binding(server) do
    binding =
      case ProviderAccountGeneration.issue_binding(server, :codex, :app_server) do
        {:ok, binding} -> binding
        {:error, _reason} -> Continuity.issue(server, :codex, :app_server)
      end

    context = make_ref()
    Process.put(context_key(context), binding)
    Process.put(server_key(context), server)
    Map.put(binding, :context, context)
  end

  @spec fetch(map()) :: {:ok, GenServer.server(), reference(), reference(), String.t()} | :error
  def fetch(%{account_generation_context: context} = session) when is_reference(context) do
    with {:ok, %{binding: binding, authority: authority, topic: topic}} <- current(context) do
      {:ok, Map.get(session, :account_generation_server, ProviderAccountGeneration), binding, authority, topic}
    else
      _ -> :error
    end
  end

  def fetch(_session), do: :error

  @spec clear(map()) :: :ok
  def clear(%{account_generation_context: context}) when is_reference(context) do
    forget_continuity(context)
    Process.put(context_key(context), :cleared)
    :ok
  end

  def clear(_session), do: :ok

  defp current(context) do
    case Process.get(context_key(context)) do
      %{binding: binding, authority: authority, topic: topic}
      when is_reference(binding) and is_reference(authority) and is_binary(topic) ->
        {:ok, %{binding: binding, authority: authority, topic: topic}}

      _ ->
        :error
    end
  end

  defp forget_continuity(context) do
    with {:ok, %{binding: binding}} <- current(context),
         server <- Process.get(server_key(context), ProviderAccountGeneration) do
      Continuity.forget(Continuity.service_id(server), {:codex, :app_server, binding})
    end
  end

  defp context_key(context), do: {Aiur.Codex.AccountGeneration, :binding_context, context}
  defp server_key(context), do: {Aiur.Codex.AccountGeneration, :binding_context_server, context}
end

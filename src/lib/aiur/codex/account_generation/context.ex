defmodule Aiur.Codex.AccountGeneration.Context do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration

  @spec new_binding(GenServer.server()) :: map()
  def new_binding(server) do
    binding =
      case ProviderAccountGeneration.issue_binding(server, :codex, :app_server) do
        {:ok, binding} -> binding
        {:error, _reason} -> %{binding: make_ref(), authority: make_ref(), topic: mint_topic()}
      end

    context = make_ref()
    Process.put(context_key(context), binding)
    Map.put(binding, :context, context)
  end

  @spec fetch(map()) :: {:ok, GenServer.server(), reference(), reference(), String.t()} | :error
  def fetch(session) do
    with {:ok, context} <- Map.fetch(session, :account_generation_context),
         true <- is_reference(context),
         {:ok, %{binding: binding, authority: authority, topic: topic}} <- current(context),
         true <- is_reference(binding) and is_reference(authority) and is_binary(topic) do
      {:ok, Map.get(session, :account_generation_server, ProviderAccountGeneration), binding, authority, topic}
    else
      _ -> :error
    end
  end

  @spec clear(map()) :: :ok
  def clear(%{account_generation_context: context}) when is_reference(context) do
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

  defp context_key(context), do: {Aiur.Codex.AccountGeneration, :binding_context, context}
  defp mint_topic, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end

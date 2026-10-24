defmodule AiurWeb.Build.ConversationSource do
  @moduledoc "Read seam for ticket conversations, independent of the retained history store."

  @type ref :: map()
  @type view :: map()
  @callback prepare(ref(), keyword()) :: {:ok, ref()} | {:error, term()}
  @callback tail(ref(), String.t() | nil, keyword()) :: {:ok, view()} | {:error, term()}
  @callback page(ref(), String.t(), keyword()) :: {:ok, view()} | {:error, term()}
  @callback subscribe(ref(), keyword()) :: :ok | {:error, term()}
  @callback unsubscribe(ref(), keyword()) :: :ok | {:error, term()}
  @callback events(ref(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback events_subscribe(term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback events_unsubscribe(String.t(), keyword()) :: :ok
  @optional_callbacks prepare: 2, events: 2, events_subscribe: 2, events_unsubscribe: 2

  @spec source() :: module() | {module(), keyword()}
  def source, do: Application.get_env(:aiur, :build_conversation_source, AiurWeb.Build.ConversationSource.Wave0b)

  @spec call(module() | {module(), keyword()}, atom(), list()) :: term()
  def call({module, opts}, function, args), do: safe_apply(module, function, args ++ [opts])
  def call(module, function, args), do: safe_apply(module, function, args ++ [[]])

  defp safe_apply(module, :prepare, [ref, opts]) do
    if Code.ensure_loaded?(module) and function_exported?(module, :prepare, 2), do: module.prepare(ref, opts), else: {:ok, ref}
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_apply(module, :events, [ref, opts]) do
    if Code.ensure_loaded?(module) and function_exported?(module, :events, 2), do: module.events(ref, opts), else: {:error, :unsupported}
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_apply(module, function, args) do
    apply(module, function, args)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end

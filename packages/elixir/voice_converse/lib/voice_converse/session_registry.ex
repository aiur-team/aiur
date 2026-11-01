defmodule VoiceConverse.SessionRegistry do
  @moduledoc false

  @spec name(module()) :: module()
  def name(instance), do: Module.concat(instance, Registry)

  @spec via(module(), String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(instance, conversation_id), do: {:via, Registry, {name(instance), conversation_id}}

  @spec register_client(module(), keyword(), String.t(), term()) :: :ok
  def register_client(instance, opts, id, target) do
    if key = Keyword.get(opts, :client_session_key) do
      {:ok, _} = Registry.register(name(instance), {:client, key}, {id, target})
    end

    :ok
  end

  @spec client(module(), term()) :: {:ok, pid(), String.t(), term()} | :error
  def client(instance, key) do
    case Registry.lookup(name(instance), {:client, key}) do
      [{pid, {id, target}}] -> {:ok, pid, id, target}
      [] -> :error
    end
  end

  @spec lookup(module(), String.t()) :: {:ok, pid()} | :error
  def lookup(instance, conversation_id) do
    case Registry.lookup(name(instance), conversation_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end

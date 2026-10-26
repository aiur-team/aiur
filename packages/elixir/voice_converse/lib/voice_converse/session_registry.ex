defmodule VoiceConverse.SessionRegistry do
  @moduledoc false

  @spec name(module()) :: module()
  def name(instance), do: Module.concat(instance, Registry)

  @spec via(module(), String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(instance, conversation_id), do: {:via, Registry, {name(instance), conversation_id}}

  @spec lookup(module(), String.t()) :: {:ok, pid()} | :error
  def lookup(instance, conversation_id) do
    case Registry.lookup(name(instance), conversation_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end

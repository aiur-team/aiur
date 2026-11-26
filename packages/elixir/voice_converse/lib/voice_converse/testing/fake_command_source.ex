defmodule VoiceConverse.Testing.FakeCommandSource do
  @moduledoc "Fake source. The target is a map; `:commands` is the open list, `:stale` makes `answer/4` fail."
  @behaviour VoiceConverse.Ports.CommandSource

  @impl true
  def open(t), do: {:ok, Map.get(t, :commands, [])}

  @impl true
  def answer(t, _id, _choice, _key), do: if(t[:stale], do: {:error, :stale}, else: :ok)

  @impl true
  def subscribe(_t, _pid), do: :unsupported
end

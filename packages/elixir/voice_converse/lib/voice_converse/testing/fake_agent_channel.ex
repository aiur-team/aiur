defmodule VoiceConverse.Testing.FakeAgentChannel do
  @moduledoc "Fake channel. The target is a map; if it has `:test_pid`, each call is sent there as `{:fake_channel, call}`."
  @behaviour VoiceConverse.Ports.AgentChannel

  @impl true
  def ask(t, question, ref, _opts), do: record(t, {:ask, question, ref})

  @impl true
  def instruct(t, text, key, _opts), do: record(t, {:instruct, text, key})

  @impl true
  def fork_query(_t, _question, _opts), do: {:error, :unsupported}

  @impl true
  def subscribe(_t, _pid), do: :unsupported

  @impl true
  def capabilities(_t), do: %{fork: :none}

  defp record(t, call) do
    if pid = t[:test_pid], do: send(pid, {:fake_channel, call})
    {:ok, make_ref()}
  end
end

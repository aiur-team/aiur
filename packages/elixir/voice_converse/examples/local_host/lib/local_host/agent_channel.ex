defmodule LocalHost.AgentChannel do
  @moduledoc "NDJSON agent bridge. A record is delivered only after its append succeeds."
  @behaviour VoiceConverse.Ports.AgentChannel
  @impl true
  def ask(target, text, _ref, _opts), do: write("ask", target, text, id())
  @impl true
  def instruct(target, text, key, _opts), do: write("instruct", target, text, key)
  @impl true
  def subscribe(target, pid), do: LocalHost.Files.subscribe({:agent, target}, pid)
  @impl true
  def capabilities(target) do
    %{fork: fork_capability(target), ask: true, listener_mode: :async}
  end

  @impl true
  def fork_query(%{session_handle: handle}, question, opts),
    do: VoiceConverse.AgentFork.fork(handle, question, opts)

  def fork_query(_target, _question, _opts), do: {:error, :unsupported}
  defp fork_capability(%{session_handle: handle}), do: VoiceConverse.AgentFork.capability(handle)
  defp fork_capability(_target), do: :none

  defp write(type, target, text, key) do
    LocalHost.Files.append(%{type: type, target: target, text: text, ref: key})
  end

  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end

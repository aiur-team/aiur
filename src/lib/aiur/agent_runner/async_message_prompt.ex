defmodule Aiur.AgentRunner.AsyncMessagePrompt do
  @moduledoc false

  alias Aiur.Orchestrator

  @spec build(String.t(), keyword()) :: String.t()
  def build(identifier, opts), do: render(Orchestrator.listener_prompt_context(identifier, opts))

  defp render({:ok, %{effective: :async, unread_count: count}}) do
    """

    ## Async operator messages

    Messages from the operator are held rather than shown automatically.
    Call `aiur_read_messages` at natural pauses and before finishing. Before concluding that no further work remains or handing back, read and act on every pending operator message.#{if is_integer(count) and count > 0, do: " #{count} unread", else: ""}
    """
  end

  defp render(_unknown_or_other_mode), do: ""
end

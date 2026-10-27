defmodule Aiur.AgentRunner.AsyncMessagePrompt do
  @moduledoc false

  alias Aiur.{Listener, Orchestrator}
  alias Aiur.Listener.Scheduler

  @spec build(String.t(), keyword()) :: String.t()
  def build(identifier, opts) do
    if Scheduler.routing(opts) == :listener do
      reader = Keyword.get(opts, :listener_prompt_reader, &context/1)
      render(reader.(identifier))
    else
      ""
    end
  end

  defp context(identifier) do
    with {:ok, %{effective: :async}} <- Listener.get_mode(identifier) do
      count =
        case Orchestrator.control_capabilities(identifier) do
          {:ok, %{listener: %{unread_count: count}}} -> count
          _unavailable -> nil
        end

      {:ok, %{effective: :async, unread_count: count}}
    end
  end

  defp render({:ok, %{effective: :async, unread_count: count}}) do
    """

    ## Async operator messages

    Messages from the operator are held rather than shown automatically.
    Call `aiur_read_messages` at natural pauses and before finishing.#{if is_integer(count) and count > 0, do: " #{count} unread", else: ""}
    """
  end

  defp render(_unknown_or_other_mode), do: ""
end

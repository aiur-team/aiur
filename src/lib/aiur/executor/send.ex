defmodule Aiur.Executor.Send do
  @moduledoc "Capability-gated Executor messages through the listener delivery port."
  alias Aiur.Conversation.Ref
  alias Aiur.Executor.Session
  alias Aiur.Listener

  @type capability :: :available | {:unavailable, atom()}

  @spec capability(keyword()) :: capability()
  def capability(opts \\ []) do
    binding = Keyword.get(opts, :binding_fun, &Session.current/0).()

    cond do
      binding == :none -> {:unavailable, :not_attached}
      not live?(binding) -> {:unavailable, :executor_unreachable}
      not Keyword.get(opts, :delivery_fun, &Listener.executor_delivery_installed?/0).() -> {:unavailable, :executor_delivery_not_installed}
      not Keyword.get_lazy(opts, :writable, &Aiur.Config.dashboard_writable?/0) -> {:unavailable, :read_only}
      true -> :available
    end
  catch
    :exit, _ -> {:unavailable, :executor_unreachable}
  end

  @spec send(String.t(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def send(text, client_request_id, opts \\ []) do
    case capability(opts) do
      :available -> Listener.send(Ref.executor(), text, origin: :agent_chat, client_request_id: client_request_id)
      {:unavailable, reason} -> {:error, reason}
    end
  end

  defp live?({:ok, %{live?: true, state: "attached", provider_session_id: id}}), do: is_binary(id) and id != ""
  defp live?(_binding), do: false
end

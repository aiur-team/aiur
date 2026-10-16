defmodule Aiur.Harness.Capabilities do
  @moduledoc "Derived support for optional harness callbacks."

  @type callback_support :: %{
          steer: :native | :none,
          native_question_reply: :native | :none
        }

  @doc "Report implemented optional callbacks for a registered backend."
  @spec callback_support(Aiur.CodingAgent.backend()) :: callback_support() | {:error, :unknown_backend}
  def callback_support(backend) do
    case Map.fetch(Aiur.CodingAgent.backends(), backend) do
      {:ok, entry} -> callback_support_for_module(entry.adapter)
      :error -> {:error, :unknown_backend}
    end
  end

  @doc "Report callback exports after loading the adapter; native questions require reply and release."
  @spec callback_support_for_module(module()) :: callback_support()
  def callback_support_for_module(adapter) do
    {:module, ^adapter} = Code.ensure_loaded(adapter)

    %{
      steer: support(function_exported?(adapter, :steer, 3)),
      native_question_reply:
        support(
          function_exported?(adapter, :reply_native_question, 3) and
            function_exported?(adapter, :release_native_question, 3)
        )
    }
  end

  defp support(true), do: :native
  defp support(false), do: :none
end

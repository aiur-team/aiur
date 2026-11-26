defmodule Aiur.Config.SemanticChecks do
  @moduledoc "Evaluates exclusive checks until a final result, then every always check in order."

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(settings) do
    case Application.get_env(:aiur, :config_semantic_checks) do
      [exclusive: [_ | _] = exclusive, always: [_ | _] = always] ->
        with :ok <- validate_exclusive(exclusive, settings) do
          validate_always(always, settings)
        end

      _ ->
        {:error, :config_checks_unregistered}
    end
  end

  defp validate_always(checks, settings) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case check.check(settings) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_exclusive(checks, settings) do
    Enum.reduce_while(checks, :ok, fn check, :ok -> exclusive_step(check, settings) end)
  end

  defp exclusive_step(check, settings) do
    case if(check.applies?(settings), do: check.check(settings), else: :continue) do
      :continue -> {:cont, :ok}
      result -> {:halt, result}
    end
  end
end

defmodule Aiur.Commands.OverrideContextTest do
  # Rebinds the VM-global delivery target.
  use ExUnit.Case, async: false

  alias Aiur.Commands.OverrideContext

  defmodule Target do
    def override_context(identifier), do: %{pr: %{number: identifier}, worker: :active, capacity: :full}
  end

  setup do
    previous = Application.fetch_env(:aiur, :commands_delivery_target)
    Application.put_env(:aiur, :commands_delivery_target, Target)

    on_exit(fn ->
      case previous do
        {:ok, target} -> Application.put_env(:aiur, :commands_delivery_target, target)
        :error -> Application.delete_env(:aiur, :commands_delivery_target)
      end
    end)
  end

  test "resolves context through the port and preserves unrelated options" do
    assert OverrideContext.options("6908", actor: :operator) == [
             override_context: %{pr: %{number: "6908"}, worker: :active, capacity: :full},
             actor: :operator
           ]
  end

  test "an explicit context is retained without resolving the port" do
    Application.put_env(:aiur, :commands_delivery_target, __MODULE__)
    opts = [override_context: %{pr: :unknown, worker: :resumable, capacity: :available}]
    assert OverrideContext.options("6908", opts) == opts
  end

  test "a legacy target with no optional callback returns explicit unknown observations" do
    Application.put_env(:aiur, :commands_delivery_target, __MODULE__)

    assert OverrideContext.options("6908", []) == [
             override_context: %{pr: :unknown, worker: :unknown, capacity: :unknown}
           ]
  end
end

defmodule Aiur.TestScopeGuard do
  @scope_env [
    "AIUR_DEV_TEST_TICKET_IDS",
    "AIUR_DEV_TEST_STATE_DIR",
    "AIUR_DASHBOARD_USERNAME",
    "AIUR_DASHBOARD_PASSWORD"
  ]

  defmacro __using__(_opts) do
    quote do
      setup_all do
        scope_state = Aiur.TestScopeGuard.capture()
        on_exit(fn -> Aiur.TestScopeGuard.assert_restored!(scope_state, __MODULE__) end)
        :ok
      end
    end
  end

  def capture do
    %{
      env: Map.new(@scope_env, &{&1, System.get_env(&1)}),
      decision_state_dir: Application.fetch_env(:aiur, :decision_state_dir)
    }
  end

  def violation(previous) do
    changes =
      Enum.flat_map(@scope_env, fn name ->
        current = System.get_env(name)
        before = Map.fetch!(previous.env, name)
        if current == before, do: [], else: ["#{name} #{inspect(before)} -> #{inspect(current)}"]
      end)

    current_decision_state_dir = Application.fetch_env(:aiur, :decision_state_dir)

    changes =
      if current_decision_state_dir == previous.decision_state_dir do
        changes
      else
        [":aiur, :decision_state_dir #{inspect(previous.decision_state_dir)} -> #{inspect(current_decision_state_dir)}" | changes]
      end

    case changes do
      [] -> nil
      changes -> "test scope state leaked: " <> Enum.join(changes, ", ")
    end
  end

  def restore(previous) do
    Enum.each(@scope_env, fn name -> restore_env(name, Map.fetch!(previous.env, name)) end)

    case previous.decision_state_dir do
      :error -> Application.delete_env(:aiur, :decision_state_dir)
      {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
    end

    :ok
  end

  def assert_restored!(previous, module) do
    violation = violation(previous)
    restore(previous)
    if violation, do: raise("#{inspect(module)}: #{violation}")
    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

defmodule Aiur.Config.PathsBuildQueueTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Paths

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    original_key = System.get_env("AIUR_INSTANCE_KEY")

    on_exit(fn ->
      if original_override,
        do: Application.put_env(:aiur, :decision_state_dir, original_override),
        else: Application.delete_env(:aiur, :decision_state_dir)

      if original_key,
        do: System.put_env("AIUR_INSTANCE_KEY", original_key),
        else: System.delete_env("AIUR_INSTANCE_KEY")
    end)
  end

  test "build queue gets its own leaf beneath the qualified state root" do
    root = Path.join(System.tmp_dir!(), "build-queue-path-test-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, root)
    assert Paths.build_queue_dir() == {:ok, Path.join(root, "build-queue")}
  end

  test "build queue propagates state root errors" do
    Application.delete_env(:aiur, :decision_state_dir)
    System.delete_env("AIUR_INSTANCE_KEY")
    assert Paths.build_queue_dir() == {:error, :missing_instance_key}
  end
end

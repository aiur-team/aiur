defmodule AiurWeb.StreamdeckLiveInstanceTest do
  use AiurWeb.StreamdeckLiveCase

  setup do
    previous = System.get_env("AIUR_INSTANCE_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("AIUR_INSTANCE_KEY", previous),
        else: System.delete_env("AIUR_INSTANCE_KEY")
    end)
  end

  test "names the current instance without offering browser instance switching" do
    System.put_env("AIUR_INSTANCE_KEY", "remote")
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, "#sd-instance", "Instance: remote")
    refute has_element?(view, "[phx-click=instance-switch]")
  end

  test "renders unavailable identity as unknown instead of inventing local" do
    System.delete_env("AIUR_INSTANCE_KEY")
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    assert has_element?(view, "#sd-instance", "Instance: unknown")
  end
end

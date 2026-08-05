defmodule Aiur.OpenAICompat.Session do
  @moduledoc false

  use Agent

  @spec start_link(map()) :: Agent.on_start()
  def start_link(state), do: Agent.start_link(fn -> state end)

  @spec get(pid()) :: map()
  def get(pid), do: Agent.get(pid, & &1)

  @spec update(pid(), (map() -> map())) :: :ok
  def update(pid, fun), do: Agent.update(pid, fun)

  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: Agent.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end
end

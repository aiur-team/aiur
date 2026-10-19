defmodule Aiur.FeaturesStoreCleanup do
  @moduledoc false

  def stop(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, :infinity)
    end
  catch
    :exit, _reason -> :ok
  end
end

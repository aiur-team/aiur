defmodule Aiur.ResourceStoreTestSupport do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Aiur.GitHub.ResourceStore

  defmacro __using__(_opts) do
    quote do
      import Aiur.ResourceStoreTestSupport, warn: false

      setup do
        dir = Aiur.TestSupport.tmp_root!("aiur-resource-store")
        File.mkdir_p!(dir)
        path = Path.join(dir, "github_resources.json")

        on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

        {:ok, path: path, dir: dir}
      end

      setup do
        on_exit(fn ->
          Application.delete_env(:aiur, :github_resource_store_path)

          case Process.whereis(ResourceStore) do
            nil -> Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
            _pid -> :ok
          end

          ResourceStore.reset()
        end)

        :ok
      end
    end
  end

  # Backdates a suppression mark's own timestamp, leaving the entry otherwise
  # untouched, so the ageing path under test is the real one.
  def age_mark!(key, by_ms) do
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, Map.update!(entry, :processed_at_ms, &(&1 - by_ms))})
    :ok
  end

  def stop_store! do
    case Process.whereis(ResourceStore) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> flunk("ResourceStore did not stop")
        end
    end
  end

  def restart_store!(path) do
    stop_store!()
    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    :ok
  end

  # Bounded and de-duplicated: the rollback sampler spins, so one rollback is
  # otherwise observed thousands of times and the report it produces is
  # unreadable. Keeping the sequence is the point — the shape of the backwards
  # steps is what names the mechanism.
  def record_backwards([pair | _rest] = backwards, pair), do: backwards
  def record_backwards(backwards, _pair) when length(backwards) >= 8, do: backwards
  def record_backwards(backwards, pair), do: [pair | backwards]
end

defmodule Aiur.TestSupport.ProviderAccountGeneration do
  @moduledoc false

  import ExUnit.Assertions

  alias Aiur.ProviderAccountGeneration

  def issued_binding(owner, provider \\ :codex) do
    assert {:ok, binding} = ProviderAccountGeneration.issue_binding(owner, provider, :app_server)
    binding
  end

  def start_owner(opts) do
    {:ok, owner} = ProviderAccountGeneration.start_link(Keyword.put(opts, :name, nil))
    owner
  end

  def sequence_mint(test_pid) do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      value = :counters.get(counter, 1)
      send(test_pid, :minted)
      "generation-#{value}"
    end
  end

  def stop_named_owner(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end

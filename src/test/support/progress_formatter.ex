defmodule Aiur.TestSupport.ProgressFormatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:test_started, %ExUnit.Test{} = test}, state) do
    IO.puts(:stdio, "test-started: #{test_name(test)}")
    {:noreply, state}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    IO.puts(:stdio, "test-finished: #{test_name(test)}")
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp test_name(test), do: "#{inspect(test.module)} #{test.name}"
end

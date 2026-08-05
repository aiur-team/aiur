defmodule Aiur.OpenAICompat.ConcurrencyTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.Concurrency

  test "reports the remaining local in-flight count after a request releases its slot" do
    backend = "test-#{System.unique_integer([:positive])}"

    assert {:done, 0} = Concurrency.with_slot(backend, fn -> :done end)
    assert Concurrency.current(backend) == 0
  end
end

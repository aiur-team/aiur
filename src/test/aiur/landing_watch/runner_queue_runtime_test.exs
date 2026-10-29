defmodule Aiur.LandingWatch.RunnerQueueRuntimeTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch

  test "runner queue reporting receives the observations already fetched by the poll" do
    parent = self()
    observations = [%{number: 17, head: "head-17"}]

    assert :ok =
             LandingWatch.poll(
               observe_fun: fn _ ->
                 send(parent, :observed)
                 {:ok, observations}
               end,
               journal_prune_fun: fn _, _ -> :ok end,
               runner_queue_fun: fn observed, _ ->
                 send(parent, {:runner_queue, observed})
                 :ok
               end,
               queue_reconcile_fun: fn _, _ -> :ok end,
               process_fun: fn _, _ -> :ok end
             )

    assert_received :observed
    assert_received {:runner_queue, ^observations}
    refute_received :observed
  end
end

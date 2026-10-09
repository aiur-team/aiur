defmodule Aiur.PRLifecycle.HealthScannerChildOrderTest do
  use ExUnit.Case, async: true

  test "pr-lifecycle health scanner keeps its supervision position with and without the ticker" do
    for ticker? <- [true, false], headless? <- [true, false] do
      children =
        Aiur.Application.child_specs(interactive_cli?: not headless?, ls_remote_ticker?: ticker?, headless?: headless?, dashboard?: false)
        |> Enum.map(&Supervisor.child_spec(&1, []).id)

      projections = Enum.find_index(children, &(&1 == Aiur.CurrentRunProjections))
      scanner = Enum.find_index(children, &(&1 == Aiur.PRLifecycle.HealthScanner))
      requeue = Enum.find_index(children, &(&1 == Aiur.Orchestrator.ReworkRequeue))

      assert is_integer(scanner)
      assert scanner == projections + if(ticker?, do: 2, else: 1)
      assert requeue == scanner + 1

      if ticker? do
        assert Enum.at(children, scanner - 1) == Aiur.Events.LsRemoteTicker
      else
        refute Aiur.Events.LsRemoteTicker in children
      end
    end
  end
end

defmodule Aiur.GitHub.ViewStateSweepWiringTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.ViewStateSweep

  test "composition root wires PackStatus as the only sweep source" do
    children =
      Aiur.Application.child_specs(
        interactive_cli?: false,
        headless?: true,
        dashboard?: false,
        tailscale_funnel?: false
      )

    assert {ViewStateSweep, sources: [Aiur.BuildOrder.PackStatus]} in children
  end

  test "standalone sweep defaults to no sources" do
    pid =
      start_supervised!({ViewStateSweep, name: nil, interval_ms: 3_600_000, repo_fun: fn -> {:error, :unconfigured} end})

    assert :sys.get_state(pid).sources == []
    assert ViewStateSweep.sweep_now(pid) == []
  end
end

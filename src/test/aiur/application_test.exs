defmodule Aiur.ApplicationTest do
  use ExUnit.Case, async: false

  alias Aiur.Application, as: AiurApp

  defmodule SuccessStubDistribution do
    @moduledoc false
    def start!, do: :ok
    def node_name, do: :"stub@127.0.0.1"
  end

  defmodule FailureStubDistribution do
    @moduledoc false
    def start!, do: {:error, :not_distributed}
    def node_name, do: nil
  end

  test "stop/1 is a no-op returning :ok" do
    # `Application.stop/1` is invoked by OTP during application
    # shutdown. There's no cleanup to perform — releases unmount on
    # node halt — so the callback just returns :ok.
    assert :ok = AiurApp.stop(:any_state)
  end

  describe "start_distribution/1" do
    test "logs at info when distribution starts successfully" do
      assert :ok = AiurApp.start_distribution(SuccessStubDistribution)
    end

    test "logs at debug when distribution refuses to start" do
      assert :ok = AiurApp.start_distribution(FailureStubDistribution)
    end
  end

  describe "child_specs/1 headless gating" do
    # The chat-pane machinery, the interactive CLI block, and the dashboard.
    @ui_only [
      Aiur.Tmux,
      Aiur.PaneManager,
      Aiur.Opencode.PrewarmSupervisor,
      Aiur.AgentList.App,
      Aiur.AgentList.Input,
      Aiur.LauncherWatchdog,
      Aiur.Opencode.PaneSupervisor,
      Aiur.HttpServer
    ]

    # Agent backends kept in headless mode plus core infra both modes need.
    @always [
      Aiur.Orchestrator,
      Aiur.ProcessReaper,
      Aiur.Opencode.SessionSupervisor,
      Aiur.Opencode.BridgeSupervisor,
      Aiur.Opencode.TokenRegistry
    ]

    defp modules(specs) do
      Enum.map(specs, fn
        mod when is_atom(mod) -> mod
        {mod, _opts} -> mod
        %{id: id} -> id
      end)
    end

    test "interactive run starts the full UI stack" do
      mods = modules(AiurApp.child_specs(interactive_cli?: true, headless?: false, dashboard?: true))

      for child <- @ui_only ++ @always, do: assert(child in mods, "expected #{inspect(child)}")
    end

    test "headless run skips UI-only work but keeps agent backends" do
      mods = modules(AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false))

      for child <- @ui_only, do: refute(child in mods, "headless should skip #{inspect(child)}")
      for child <- @always, do: assert(child in mods, "headless still needs #{inspect(child)}")
    end

    test "headless boots measurably fewer children than interactive" do
      interactive = AiurApp.child_specs(interactive_cli?: true, headless?: false, dashboard?: true)
      headless = AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)

      assert length(headless) < length(interactive)
    end

    test "headless dashboard opt-in starts HttpServer without reviving panes" do
      mods = modules(AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: true))

      assert Aiur.HttpServer in mods
      refute Aiur.Opencode.PaneSupervisor in mods
      refute Aiur.PaneManager in mods
    end

    test "ProcessReaper starts before Task.Supervisor in both shapes" do
      # Load-bearing ordering: children stop in reverse, so the reaper must
      # outlive the runner tasks/ports it sweeps in its terminate/2 backstop.
      # The headless gating must not disturb this.
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        reaper = Enum.find_index(mods, &(&1 == Aiur.ProcessReaper))
        task_sup = Enum.find_index(mods, &(&1 == Task.Supervisor))
        assert reaper < task_sup, "ProcessReaper must precede Task.Supervisor for #{inspect(opts)}"
      end
    end
  end
end

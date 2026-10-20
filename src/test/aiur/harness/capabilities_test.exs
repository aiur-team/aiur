defmodule Aiur.Harness.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent.Registry
  alias Aiur.Harness.Capabilities

  # future adapter: gemini (PR #2870)
  @rows [
    {"codex", :app_server_stdio, :none, :in_band, false, true, []},
    {"claude", :app_server_stdio, :none, :in_band, false, true, []},
    {"claude-repl", :tmux_pane, :native, :out_of_band, true, false, [:prompt, :tool, :stop]},
    {"muse", :msp_stdio, :none, :in_band, false, true, []},
    {"kimi", :in_process_http, :native, :none, false, true, []},
    {"deepseek", :in_process_http, :native, :none, false, true, []},
    {"openrouter", :in_process_http, :native, :none, false, true, []},
    {"fake", :unknown, :none, :none, false, false, []}
  ]

  test "delivery primitives match the declared table for every registered harness" do
    assert Enum.sort(Map.keys(Registry.entries())) == Enum.sort(Enum.map(@rows, &elem(&1, 0)))

    for {key, transport, inject, interrupt, queue, pull, hooks} <- @rows do
      assert Capabilities.delivery_primitives(key) ==
               {:ok,
                %{
                  harness_id: key,
                  transport: transport,
                  turn_boundary_start: true,
                  mid_turn_inject: inject,
                  hard_interrupt: interrupt,
                  native_queue: queue,
                  pull_tool: pull,
                  hook_boundaries: hooks,
                  native_question: :none
                }}
    end
  end

  test "an undeclared entry gets conservative defaults" do
    assert Capabilities.delivery_primitives_for_entry("undeclared", %{adapter: __MODULE__}) == %{
             harness_id: "undeclared",
             transport: :unknown,
             turn_boundary_start: false,
             mid_turn_inject: :none,
             hard_interrupt: :none,
             native_queue: false,
             pull_tool: false,
             hook_boundaries: [],
             native_question: :none
           }
  end

  test "an unknown backend is reported rather than defaulted" do
    assert Capabilities.delivery_primitives("unknown-harness") == {:error, :unknown_backend}
  end

  test "interrupt derivation follows flags and exports regardless of backend name" do
    repl = Registry.entries()["claude-repl"]
    codex = Registry.entries()["codex"]

    assert %{hard_interrupt: :out_of_band, native_queue: true} =
             Capabilities.delivery_primitives_for_entry("renamed", repl)

    assert %{hard_interrupt: :in_band, native_queue: false} =
             Capabilities.delivery_primitives_for_entry("claude-repl", codex)

    assert %{hard_interrupt: :none} =
             Capabilities.delivery_primitives_for_entry("renamed", %{repl | can_interrupt: false})
  end
end

defmodule AiurWeb.UsageGasApiControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Aiur.Usage.{AccountingView, GasLedger}
  alias AiurWeb.UsageGasApiController

  test "records a fal charge and exposes it as Gas against the configured budget" do
    root = Aiur.TestSupport.tmp_root!("usage-gas-api")
    previous_server = Application.get_env(:aiur, :usage_gas_ledger_server)
    previous_budget = System.get_env("AIUR_GAS_BUDGET_USD")
    previous_user = System.get_env("AIUR_USAGE_USER_ID")
    server_name = String.to_atom("usage_gas_api_#{System.unique_integer([:positive])}")
    {:ok, ledger} = GasLedger.start_link(name: server_name, state_dir: root)
    Application.put_env(:aiur, :usage_gas_ledger_server, ledger)
    System.put_env("AIUR_GAS_BUDGET_USD", "10.00")
    System.put_env("AIUR_USAGE_USER_ID", "host-user-7")

    on_exit(fn ->
      restore_env("AIUR_GAS_BUDGET_USD", previous_budget)
      restore_env("AIUR_USAGE_USER_ID", previous_user)

      if previous_server,
        do: Application.put_env(:aiur, :usage_gas_ledger_server, previous_server),
        else: Application.delete_env(:aiur, :usage_gas_ledger_server)

      Aiur.TestCleanup.rm_rf!(root)
    end)

    params = %{
      "id" => "fal-charge-8156",
      "user_id" => "host-user-7",
      "api" => "fal",
      "amount_usd" => "1.25",
      "occurred_at" => "2026-11-27T12:00:00Z",
      "basis" => "actual",
      "ticket" => "8156"
    }

    response = conn(:post, "/api/v1/usage/gas") |> UsageGasApiController.create(params)
    assert response.status == 201

    view =
      AccountingView.build("host-user-7",
        usage_source: %{cells: %{}, metadata: %{health: :healthy}},
        gas_ledger_server: ledger
      )

    assert view.gas.status == "available"
    assert view.gas.budget_usd == "10.00"
    assert view.gas.spent_usd == "1.25"
    assert view.gas.remaining_usd == "8.75"
    assert Map.fetch!(view.gas.records, "fal") == [%{amount_usd: "1.25", occurred_at: "2026-11-27T12:00:00Z", basis: "actual", ticket: "8156", conversation_id: nil}]
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

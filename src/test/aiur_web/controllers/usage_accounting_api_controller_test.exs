defmodule AiurWeb.UsageAccountingApiControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AiurWeb.UsageAccountingApiController

  test "returns the versioned per-user actual usage view without caching it" do
    previous = Application.get_env(:aiur, :usage_accounting_opts)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :usage_accounting_opts, previous),
        else: Application.delete_env(:aiur, :usage_accounting_opts)
    end)

    Application.put_env(:aiur, :usage_accounting_opts,
      usage_source: %{
        cells: %{
          {%{provider: :codex, user_id: "u-1", ticket: :unknown, run_id: "r-1"}, {:token, :input}} => 7,
          {%{provider: :codex, user_id: "u-2", ticket: :unknown, run_id: "r-2"}, {:token, :input}} => 11
        },
        metadata: %{status: "fresh"}
      },
      meter_views: %{codex: %{windows: %{"weekly" => %{used_percent: 2, resets_at: ~U[2026-12-01 00:00:00Z]}}, observed_at: ~U[2026-11-27 00:00:00Z], freshness: :fresh}},
      now: ~U[2026-11-27 00:00:00Z]
    )

    response = conn(:get, "/api/v1/usage/users/u-1") |> UsageAccountingApiController.show(%{"user_id" => "u-1"})
    body = Jason.decode!(response.resp_body)

    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert body["contract"] == "aiur.usage.accounting"
    assert body["user_id"] == "u-1"
    assert body["minerals"]["providers"]["codex"]["tokens"]["input"] == 7
    assert body["minerals"]["allocation_periods"]["codex"]["weekly"]["resets_at"] == "2026-12-01T00:00:00Z"

    second_user = conn(:get, "/api/v1/usage/users/u-2") |> UsageAccountingApiController.show(%{"user_id" => "u-2"})
    second_body = Jason.decode!(second_user.resp_body)
    assert second_user.status == 200
    assert second_body["user_id"] == "u-2"
    assert second_body["minerals"]["providers"]["codex"]["tokens"]["input"] == 11

    unknown_user = conn(:get, "/api/v1/usage/users/u-3") |> UsageAccountingApiController.show(%{"user_id" => "u-3"})
    unknown_body = Jason.decode!(unknown_user.resp_body)
    assert unknown_user.status == 200
    assert unknown_body["user_id"] == "u-3"
    assert unknown_body["minerals"]["providers"] == %{}
  end
end

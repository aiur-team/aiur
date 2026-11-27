defmodule AiurWeb.UsageAccountingApiControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AiurWeb.UsageAccountingApiController

  test "returns the versioned per-user actual usage view without caching it" do
    previous = Application.get_env(:aiur, :usage_accounting_opts)
    previous_user_id = System.get_env("AIUR_USAGE_USER_ID")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :usage_accounting_opts, previous),
        else: Application.delete_env(:aiur, :usage_accounting_opts)

      if previous_user_id,
        do: System.put_env("AIUR_USAGE_USER_ID", previous_user_id),
        else: System.delete_env("AIUR_USAGE_USER_ID")
    end)

    System.put_env("AIUR_USAGE_USER_ID", "u-1")

    Application.put_env(:aiur, :usage_accounting_opts,
      usage_source: %{
        cells: %{{%{provider: :codex, user_id: "u-1", ticket: :unknown, run_id: "r-1"}, {:token, :input}} => 7},
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

    wrong_user = conn(:get, "/api/v1/usage/users/u-2") |> UsageAccountingApiController.show(%{"user_id" => "u-2"})
    assert wrong_user.status == 404
    assert Jason.decode!(wrong_user.resp_body)["error"]["code"] == "unknown_user"
  end
end

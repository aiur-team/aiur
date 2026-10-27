defmodule AiurWeb.UsageAccountsApiController do
  @moduledoc """
  Authenticated, read-only account and rate-limit snapshot.

  Serves the same rows as `aiur accounts --json`, read from the daemon's polled
  usage observations, inside a versioned envelope. Rows carry identity labels
  and usage only; credentials and profile paths are never read into them.
  """
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Accounts.UsageReadings
  alias Aiur.AccountsCLI

  @contract "aiur.usage.accounts"
  @contract_version 1
  # Only these fields leave the daemon; a new row or shim field stays off the
  # wire until it is added here.
  @row_fields ~w(name harness email org seat_tier identity usage weekly_percent five_hour_percent remaining_percent freshness observed_at age_ms last_error)a
  @identity_fields ~w(email organization seatTier account_id)

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    accounts = params |> harness() |> AccountsCLI.rows(&UsageReadings.snapshot("claude", &1)) |> Enum.map(&public_row/1)

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> json(%{
      contract: @contract,
      contract_version: @contract_version,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      accounts: accounts
    })
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> put_status(:method_not_allowed)
    |> json(%{error: "method_not_allowed"})
  end

  # API-key accounts have no usage meter; say so instead of omitting freshness.
  defp public_row(row) do
    row
    |> Map.take(@row_fields)
    |> Map.update(:identity, nil, &public_identity/1)
    |> Map.put_new(:freshness, "usage_unavailable")
  end

  defp public_identity(identity) when is_map(identity), do: Map.take(identity, @identity_fields)
  defp public_identity(_identity), do: nil

  defp harness(%{"harness" => harness}) when is_binary(harness) and harness != "", do: harness
  defp harness(_params), do: nil
end

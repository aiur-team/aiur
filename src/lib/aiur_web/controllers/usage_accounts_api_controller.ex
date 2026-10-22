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

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    accounts = AccountsCLI.rows(harness(params), &UsageReadings.snapshot("claude", &1))

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

  defp harness(%{"harness" => harness}) when is_binary(harness) and harness != "", do: harness
  defp harness(_params), do: nil
end

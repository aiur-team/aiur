defmodule Aiur.AccountsCLI do
  @moduledoc false

  alias Aiur.Accounts
  alias Aiur.Accounts.Shims.Claude, as: ClaudeAccounts
  @spec accounts(boolean()) :: :ok
  def accounts(json), do: accounts(json, fn _names -> %{} end)

  @doc false
  @spec accounts(boolean(), ([String.t()] -> map())) :: :ok
  def accounts(json, snapshot_fun) when is_function(snapshot_fun, 1) do
    accounts = Accounts.list("claude") |> Enum.filter(&(&1.harness == "claude"))
    names = Enum.map(accounts, & &1.name)
    snapshots = if names == [], do: %{}, else: snapshot_fun.(names)
    rows = Enum.map(accounts, &account_row(&1, snapshots))

    if json, do: IO.puts(Jason.encode!(rows)), else: Enum.each(rows, &print_row/1)
    :ok
  end

  @spec login(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def login(name, dir) do
    with {:ok, _profile_dir} <- prepare_login(name, dir),
         {command, args} <- Accounts.login_command("claude", name),
         {_output, status} <- System.cmd(command, args, into: IO.stream(:stdio, :line)) do
      if status == 0, do: :ok, else: {:error, :login_failed}
    end
  end

  @spec prepare_login(String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def prepare_login(name, dir) do
    with :ok <- validate_dir(dir),
         :ok <- Accounts.register("claude", name, dir),
         %{profile_dir: profile_dir} <- Enum.find(Accounts.list("claude"), &(&1.name == name)),
         true <- is_binary(profile_dir) do
      {:ok, profile_dir}
    else
      false -> {:error, :profile_directory_missing}
      nil -> {:error, :unknown_account}
      {:error, _} = error -> error
    end
  end

  @spec logout(String.t(), boolean()) :: :ok | {:error, term()}
  def logout(name, purge), do: Accounts.logout(name, purge)

  defp validate_dir(nil), do: :ok

  defp validate_dir(dir) when is_binary(dir) do
    if String.ends_with?(dir, "/"), do: {:error, :trailing_slash_in_dir}, else: :ok
  end

  defp account_row(%{name: name, harness: harness, profile_dir: dir}, snapshots) do
    identity = ClaudeAccounts.identity(dir)

    case snapshots do
      %{^name => %{reading: reading, observed_at: observed_at, freshness: freshness}} when is_map(reading) ->
        %{
          name: name,
          harness: harness,
          email: identity["email"],
          org: identity["organization"] || identity["orgName"],
          seat_tier: identity["seatTier"] || identity["subscriptionType"],
          weekly_percent: percent(reading.windows, "seven_day"),
          five_hour_percent: percent(reading.windows, "five_hour"),
          freshness: Atom.to_string(freshness),
          observed_at: DateTime.to_iso8601(observed_at),
          age_ms: max(DateTime.diff(DateTime.utc_now(), observed_at, :millisecond), 0)
        }

      %{^name => %{freshness: :unavailable, reason: reason}} ->
        usage_unavailable_row(name, harness, identity, Atom.to_string(reason))

      _unavailable ->
        usage_unavailable_row(name, harness, identity, "daemon_not_running")
    end
  end

  defp usage_unavailable_row(name, harness, identity, freshness) do
    %{
      name: name,
      harness: harness,
      email: identity["email"],
      org: identity["organization"] || identity["orgName"],
      seat_tier: identity["seatTier"] || identity["subscriptionType"],
      weekly_percent: nil,
      five_hour_percent: nil,
      freshness: freshness,
      observed_at: nil,
      age_ms: nil
    }
  end

  defp percent(windows, id) do
    case Enum.find(windows, &(&1.window == id)) do
      %{used_percent: percent} -> percent
      _missing -> nil
    end
  end

  defp print_row(row) do
    IO.puts(
      Enum.map_join([:name, :harness, :email, :org, :seat_tier, :weekly_percent, :five_hour_percent, :freshness], "  ", fn key ->
        "#{key}=#{inspect(Map.get(row, key))}"
      end)
    )
  end
end

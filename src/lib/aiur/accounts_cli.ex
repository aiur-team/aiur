defmodule Aiur.AccountsCLI do
  @moduledoc false

  @spec accounts(boolean()) :: :ok | {:error, term()}
  def accounts(json) do
    rows = Enum.map(Aiur.Accounts.list("claude"), &account_row/1)
    if json, do: IO.puts(Jason.encode!(rows)), else: Enum.each(rows, &print_row/1)
    :ok
  end

  @spec login(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def login(name, dir) do
    with {:ok, _profile_dir} <- prepare_login(name, dir),
         {command, args} <- Aiur.Accounts.login_command("claude", name),
         {_output, status} <- System.cmd(command, args, into: IO.stream(:stdio, :line)) do
      if status == 0, do: :ok, else: {:error, :login_failed}
    end
  end

  @spec prepare_login(String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def prepare_login(name, dir) do
    with :ok <- validate_dir(dir),
         :ok <- Aiur.Accounts.register("claude", name, dir),
         %{profile_dir: profile_dir} <- Enum.find(Aiur.Accounts.list("claude"), &(&1.name == name)),
         true <- is_binary(profile_dir) do
      {:ok, profile_dir}
    else
      false -> {:error, :profile_directory_missing}
      nil -> {:error, :unknown_account}
      {:error, _} = error -> error
    end
  end

  @spec logout(String.t(), boolean()) :: :ok | {:error, term()}
  def logout(name, purge), do: Aiur.Accounts.logout(name, purge)

  defp validate_dir(nil), do: :ok

  defp validate_dir(dir) when is_binary(dir) do
    if String.ends_with?(dir, "/"), do: {:error, :trailing_slash_in_dir}, else: :ok
  end

  defp account_row(%{name: name, harness: harness, profile_dir: dir}) do
    identity = Aiur.Accounts.Shims.Claude.identity(dir)

    case Aiur.Accounts.usage(harness, name) do
      {:ok, reading, metadata} ->
        %{
          name: name,
          harness: harness,
          email: identity["email"],
          org: identity["organization"] || identity["orgName"],
          seat_tier: identity["seatTier"] || identity["subscriptionType"],
          weekly_percent: percent(reading.windows, "seven_day"),
          five_hour_percent: percent(reading.windows, "five_hour"),
          freshness: Atom.to_string(metadata.freshness),
          observed_at: DateTime.to_iso8601(metadata.observed_at),
          age_ms: max(DateTime.diff(DateTime.utc_now(), metadata.observed_at, :millisecond), 0)
        }

      {:error, reason} ->
        %{
          name: name,
          harness: harness,
          email: identity["email"],
          org: identity["organization"] || identity["orgName"],
          seat_tier: identity["seatTier"] || identity["subscriptionType"],
          weekly_percent: nil,
          five_hour_percent: nil,
          freshness: Atom.to_string(reason),
          observed_at: nil,
          age_ms: nil
        }
    end
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

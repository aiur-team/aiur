defmodule Aiur.AccountsCLI do
  @moduledoc false

  alias Aiur.Accounts
  alias Aiur.Accounts.Shims.{Claude, Codex}

  @spec accounts(boolean(), String.t() | nil) :: :ok | {:error, term()}
  def accounts(json, harness \\ nil) do
    rows = Enum.map(Accounts.list(harness), &account_row/1)
    if json, do: IO.puts(Jason.encode!(rows)), else: Enum.each(rows, &print_row/1)
    :ok
  end

  @spec login(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def login(name, dir), do: login("claude", name, dir)

  @spec login(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def login(harness, name, dir) do
    with :ok <- maybe_validate_and_register(harness, name, dir) do
      case Accounts.capability(harness) do
        {:ok, %{kind: :api_key}} ->
          :ok

        _ ->
          launch_login(Accounts.login_command(harness, name))
      end
    end
  end

  defp launch_login({command, args}) when is_binary(command) and is_list(args) do
    {_output, status} = System.cmd(command, args, into: IO.stream(:stdio, :line))
    if status == 0, do: :ok, else: {:error, :login_failed}
  end

  defp launch_login({:error, reason}), do: {:error, reason}

  @spec prepare_login(String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def prepare_login(name, dir), do: prepare_login("claude", name, dir)

  @spec prepare_login(String.t(), String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def prepare_login(harness, name, dir) do
    with :ok <- validate_dir(dir),
         :ok <- Accounts.register(harness, name, dir),
         %{profile_dir: profile_dir} <- Enum.find(Accounts.list(harness), &(&1.name == name)),
         true <- is_binary(profile_dir) do
      {:ok, profile_dir}
    else
      false -> {:error, :profile_directory_missing}
      nil -> {:error, :unknown_account}
      {:error, _} = error -> error
    end
  end

  @spec prepare_login_result(String.t(), String.t(), String.t() | nil) :: {:ok, Path.t() | nil} | {:error, term()}
  def prepare_login_result(harness, name, dir) do
    case Accounts.capability(harness) do
      {:ok, %{kind: :api_key}} ->
        with :ok <- maybe_validate_and_register(harness, name, dir), do: {:ok, nil}

      {:ok, %{reason: reason}} ->
        {:error, {:unsupported_account_backend, reason}}

      _ ->
        prepare_login(harness, name, dir)
    end
  end

  @spec maybe_validate_and_register(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  defp maybe_validate_and_register(harness, name, dir) do
    case Accounts.capability(harness) do
      {:ok, %{kind: :api_key}} ->
        if is_nil(dir), do: Accounts.register(harness, name), else: {:error, :api_key_account_does_not_use_profile_dir}

      {:ok, %{reason: reason}} ->
        {:error, {:unsupported_account_backend, reason}}

      _ ->
        with {:ok, _profile_dir} <- prepare_login(harness, name, dir), do: :ok
    end
  end

  @spec logout(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def logout(harness, name, purge), do: Accounts.logout(harness, name, purge)
  @spec logout(String.t(), boolean()) :: :ok | {:error, term()}
  def logout(name, purge), do: Accounts.logout(name, purge)

  defp validate_dir(nil), do: :ok

  defp validate_dir(dir) when is_binary(dir) do
    if String.ends_with?(dir, "/"), do: {:error, :trailing_slash_in_dir}, else: :ok
  end

  defp account_row(%{name: name, harness: harness, profile_dir: dir}) do
    identity = identity(harness, dir)

    case Accounts.usage(harness, name) do
      {:ok, reading, metadata} ->
        %{
          name: name,
          harness: harness,
          email: identity["email"],
          org: identity["organization"] || identity["orgName"],
          seat_tier: identity["seatTier"] || identity["subscriptionType"],
          identity: identity,
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
          identity: identity,
          weekly_percent: nil,
          five_hour_percent: nil,
          freshness: freshness(reason),
          observed_at: nil,
          age_ms: nil
        }
    end
  end

  defp account_row(%{name: name, harness: harness, api_key_env: _env_name}) do
    %{name: name, harness: harness, identity: nil, usage: "usage unavailable", observed_at: nil, age_ms: nil}
  end

  defp account_row(%{name: _name, harness: _harness} = account) do
    account_row(Map.put(account, :profile_dir, nil))
  end

  defp identity("claude", dir), do: Claude.identity(dir)
  defp identity("codex", dir), do: Codex.identity(dir)
  defp identity(_harness, _dir), do: %{}

  defp freshness(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp freshness(_reason), do: "unavailable"

  defp percent(windows, id) do
    case Enum.find(windows, &(&1.window == id)) do
      %{used_percent: percent} -> percent
      _missing -> nil
    end
  end

  defp print_row(row) do
    fields = if Map.get(row, :identity) == nil, do: [:name, :harness, :usage], else: [:name, :harness, :email, :org, :seat_tier, :weekly_percent, :five_hour_percent, :freshness]
    IO.puts(Enum.map_join(fields, "  ", fn key -> "#{key}=#{inspect(Map.get(row, key))}" end))
  end
end

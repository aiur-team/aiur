defmodule Aiur.AccountsCLI do
  @moduledoc false

  alias Aiur.Accounts
  alias Aiur.Accounts.Shims.{Claude, Codex}
  alias Aiur.CodingAgent.HeadroomDispatch

  @spec accounts(boolean(), String.t() | nil) :: :ok | {:error, term()}
  def accounts(json, harness \\ nil)

  @doc false
  @spec accounts(boolean(), ([String.t()] -> map())) :: :ok
  def accounts(json, snapshot_fun) when is_function(snapshot_fun, 1) do
    render_accounts(json, nil, snapshot_fun, true)
  end

  def accounts(json, harness), do: render_accounts(json, harness, %{}, false)

  @doc false
  @spec accounts(boolean(), String.t() | nil, ([String.t()] -> map())) :: :ok
  def accounts(json, harness, snapshot_fun) when is_function(snapshot_fun, 1) do
    render_accounts(json, harness, snapshot_fun, true)
  end

  @doc false
  @spec accounts(boolean(), String.t() | nil, ([String.t()] -> map()), (String.t() -> map() | nil)) :: :ok
  def accounts(json, harness, snapshot_fun, ledger_fun) when is_function(snapshot_fun, 1) and is_function(ledger_fun, 1) do
    render_accounts(json, harness, snapshot_fun, true, ledger_fun)
  end

  defp render_accounts(json, harness, snapshot_fun, daemon_available?, ledger_fun \\ &ledger_reading/1) do
    accounts = Accounts.list(harness)
    claude_names = accounts |> Enum.filter(&(&1.harness == "claude")) |> Enum.map(& &1.name)

    snapshots =
      if is_function(snapshot_fun, 1) do
        if claude_names == [], do: %{}, else: snapshot_fun.(claude_names)
      else
        snapshot_fun
      end

    per_harness = Enum.frequencies_by(accounts, & &1.harness)

    rows =
      Enum.map(accounts, fn account ->
        ledger? = daemon_available? and Aiur.CodingAgent.family_for(account.harness) != "claude" and Map.get(per_harness, account.harness) == 1
        account |> account_row(snapshots, daemon_available?) |> with_ledger(ledger? && ledger_fun.(account.harness))
      end)

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

  defp account_row(%{name: name, harness: harness, api_key_env: _env_name}, _snapshots, _daemon_available?) do
    %{name: name, harness: harness, identity: nil, usage: "usage unavailable", remaining_percent: nil, observed_at: nil, age_ms: nil}
  end

  defp account_row(%{name: name, harness: harness, profile_dir: dir}, snapshots, daemon_available?) do
    identity = identity(harness, dir)

    case snapshot_for(harness, name, snapshots, daemon_available?) do
      {:ok, reading, observed_at, freshness} ->
        %{
          name: name,
          harness: harness,
          email: identity["email"],
          org: identity["organization"] || identity["orgName"],
          seat_tier: identity["seatTier"] || identity["subscriptionType"],
          identity: identity,
          weekly_percent: percent(reading.windows, "seven_day"),
          five_hour_percent: percent(reading.windows, "five_hour"),
          remaining_percent: HeadroomDispatch.remaining_percent(%{windows: %{"seven_day" => percent(reading.windows, "seven_day"), "five_hour" => percent(reading.windows, "five_hour")}}),
          freshness: Atom.to_string(freshness),
          observed_at: DateTime.to_iso8601(observed_at),
          age_ms: max(DateTime.diff(DateTime.utc_now(), observed_at, :millisecond), 0)
        }

      {:error, reason} ->
        usage_unavailable_row(name, harness, identity, freshness(reason))
    end
  end

  defp identity("claude", dir), do: Claude.identity(dir)
  defp identity("codex", dir), do: Codex.identity(dir)
  defp identity(_harness, _dir), do: %{}

  defp snapshot_for("claude", name, snapshots, daemon_available?) do
    case snapshots do
      %{^name => %{reading: reading, observed_at: observed_at, freshness: freshness}} when is_map(reading) ->
        {:ok, reading, observed_at, freshness}

      %{^name => %{freshness: :unavailable, reason: reason}} ->
        {:error, reason}

      _missing ->
        {:error, if(daemon_available?, do: :usage_not_observed, else: :daemon_not_running)}
    end
  end

  defp snapshot_for(_harness, _name, _snapshots, true), do: {:error, :usage_not_polled}
  defp snapshot_for(_harness, _name, _snapshots, false), do: {:error, :daemon_not_running}

  defp usage_unavailable_row(name, harness, identity, freshness) do
    %{
      name: name,
      harness: harness,
      email: identity["email"],
      org: identity["organization"] || identity["orgName"],
      seat_tier: identity["seatTier"] || identity["subscriptionType"],
      identity: identity,
      weekly_percent: nil,
      five_hour_percent: nil,
      remaining_percent: nil,
      freshness: freshness,
      observed_at: nil,
      age_ms: nil
    }
  end

  # Backends without a per-account meter (Codex today) read the usage ledger
  # that their sessions and the background probe write (#3960). The ledger is
  # per backend, so it only describes a backend with a single account.
  # A reading older than `agent.headroom_reading_max_age_seconds` is stale:
  # its numbers are not shown, only its age.
  defp with_ledger(row, %{stale: true} = reading) do
    Map.merge(row, %{freshness: "stale_ledger", age_ms: age_ms(reading)})
  end

  defp with_ledger(row, %{windows: windows} = reading) do
    Map.merge(row, %{
      weekly_percent: round_percent(windows["weekly"]),
      five_hour_percent: round_percent(windows["short"]),
      remaining_percent: HeadroomDispatch.remaining_percent(reading),
      freshness: "ledger",
      age_ms: age_ms(reading)
    })
  end

  defp with_ledger(row, _no_reading), do: row

  defp age_ms(%{age_seconds: age}) when is_integer(age), do: age * 1000
  defp age_ms(_reading), do: nil

  defp round_percent(value) when is_number(value), do: round(value)
  defp round_percent(_value), do: nil

  defp ledger_reading(harness) do
    HeadroomDispatch.backend_reading(harness)
  rescue
    _ -> nil
  end

  defp freshness(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp freshness(_reason), do: "unavailable"

  defp percent(windows, id) do
    case Enum.find(windows, &(&1.window == id)) do
      %{used_percent: percent} -> percent
      _missing -> nil
    end
  end

  defp print_row(row) do
    fields =
      if Map.get(row, :identity) == nil,
        do: [:name, :harness, :usage, :remaining_percent],
        else: [:name, :harness, :email, :org, :seat_tier, :remaining_percent, :weekly_percent, :five_hour_percent, :freshness, :age_ms]

    IO.puts(Enum.map_join(fields, "  ", fn key -> "#{key}=#{inspect(Map.get(row, key))}" end))
  end
end

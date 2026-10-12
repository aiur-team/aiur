defmodule Aiur.GitHub.TrustSnapshot do
  @moduledoc "Configured trust and degradation presentation shared by snapshot consumers."

  alias Aiur.GitHub.{CodeOwners, Config}

  @spec configured_set() :: MapSet.t(String.t())
  def configured_set do
    [repo_owner(), Config.daemon_account(), Config.bot_account() | Config.trusted_accounts()]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  @spec repo_owner() :: String.t() | nil
  def repo_owner do
    with repo when is_binary(repo) <- Config.repo(),
         [owner, name] when owner != "" and name != "" <- String.split(repo, "/") do
      String.downcase(owner)
    else
      _ -> nil
    end
  end

  @spec current() :: map() | nil
  def current do
    if Process.whereis(CodeOwners), do: CodeOwners.trust_snapshot(), else: nil
  catch
    :exit, _ -> nil
  end

  @spec degradation(map() | nil, term()) :: map() | nil
  def degradation(_previous, nil), do: nil
  def degradation(%{cause: cause} = previous, cause), do: previous
  def degradation(_previous, cause), do: %{cause: cause, observed_at: DateTime.utc_now()}

  @spec age_label(map(), DateTime.t()) :: String.t()
  def age_label(degradation, now \\ DateTime.utc_now())

  def age_label(%{observed_at: %DateTime{} = observed_at}, now) do
    "age #{max(DateTime.diff(now, observed_at), 0)}s"
  end

  def age_label(_, _now), do: "age unknown"

  @spec description(term()) :: String.t()
  def description(:missing), do: "CODEOWNERS is missing"
  def description(:empty), do: "CODEOWNERS is empty"
  def description({:unparseable, line}), do: "CODEOWNERS is unparseable near line #{line}"
  def description({:team_lookup_failed, team, reason}), do: "Team lookup failed for #{team}: #{inspect(reason)}"
  def description(:repo_owner_unknown), do: "Repository owner is unknown"
  def description(cause), do: "CODEOWNERS lookup failed: #{inspect(cause)}"

  @spec status_suffix(map(), DateTime.t()) :: String.t()
  def status_suffix(snapshot, now \\ DateTime.utc_now())

  def status_suffix(%{degradation: %{cause: cause} = degradation}, now) do
    " degraded=#{description(cause)} #{age_label(degradation, now)}"
  end

  def status_suffix(_, _now), do: ""
end

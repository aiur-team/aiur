defmodule Aiur.AllowedContributors.Refresh do
  @moduledoc """
  Re-reads the allow-list into the intake server's state and surfaces every
  change to it to the operator.

  A merged change to `.github/ALLOWED-CONTRIBUTORS` alerts
  `allowed_contributors.changed` naming the entries added and removed and both
  commit SHAs; a file that does not parse alerts `allowed_contributors.invalid`.
  Both compare against the SHA and entries remembered in the `Ledger`, so they
  fire once per merged change rather than once per refresh or per boot.

  A failed read keeps the previous snapshot: a transient outage must not flip
  trust in either direction. With no previous snapshot, intake defers.
  """

  require Logger

  alias Aiur.AllowedContributors.{AllowList, Ledger, Source}

  @spec run(map()) :: map()
  def run(state) do
    case state.token_fun.() do
      token when is_binary(token) and token != "" ->
        state.owner |> Source.fetch(state.repo, request_fun: state.request_fun, token: token) |> apply_fetch(state)

      _missing ->
        state
    end
  end

  defp apply_fetch({:error, reason}, state) do
    Logger.warning("allowed_contributors refresh_failed reason=#{inspect(reason)}")
    state
  end

  defp apply_fetch({:ok, snapshot}, state) do
    {sha, entries} = describe(snapshot)
    if sha != state.ledger.sha or entries != state.ledger.entries, do: alert_change(state, snapshot, sha, entries)
    ledger = Ledger.put_allowlist(state.ledger, sha, entries)
    :ok = Ledger.save(ledger, state.ledger_path)
    %{state | snapshot: snapshot, ledger: ledger}
  end

  defp describe(:absent), do: {nil, []}
  defp describe(%{sha: sha, allowlist: {:invalid, _reason}}), do: {sha, ["invalid"]}
  defp describe(%{sha: sha, allowlist: list}), do: {sha, AllowList.diff(AllowList.empty(), list).added}

  defp alert_change(state, %{allowlist: {:invalid, reason}}, sha, _entries) do
    state.alert_fun.(
      "allowed_contributors.invalid",
      "#{Source.path()} at #{sha} does not parse (#{inspect(reason)}); allowed-contributor intake admits nobody until it is fixed.",
      reason: "Malformed allow-list fails closed",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp alert_change(state, _snapshot, sha, entries) do
    added = entries -- state.ledger.entries
    removed = state.ledger.entries -- entries

    state.alert_fun.(
      "allowed_contributors.changed",
      "#{Source.path()} changed on the default branch (#{state.ledger.sha || "none"} -> #{sha || "absent"}): " <>
        "added #{inspect(added)}, removed #{inspect(removed)}.",
      reason: "Allowed-contributor trust set changed; confirm the change was intended",
      needs_attention: true,
      severity: "warning"
    )
  end
end

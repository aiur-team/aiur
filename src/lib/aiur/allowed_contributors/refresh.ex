defmodule Aiur.AllowedContributors.Refresh do
  @moduledoc """
  Re-reads the allow-list into the intake server's state and surfaces every
  change to it to the operator.

  Config reloads and merged changes to `.github/ALLOWED-CONTRIBUTORS` alert
  `allowed_contributors.changed` naming added/removed entries and the source
  (`config` or `file@<sha>`); a file that does not parse alerts `allowed_contributors.invalid`.
  Both compare against the SHA and entries remembered in the `Ledger`, so they
  fire once per merged change rather than once per refresh or per boot.

  A failed read keeps the previous snapshot: a transient outage must not flip
  trust in either direction. With no previous snapshot, intake defers.
  """

  require Logger

  alias Aiur.AllowedContributors.{AllowList, Ledger, Source, State}

  @spec run(State.t()) :: State.t()
  def run(state) do
    config = state.config_fun.()

    if is_nil(config), do: refresh_file(state), else: fetch(state, allowed_contributors: config)
  end

  defp refresh_file(state) do
    case state.token_fun.() do
      token when is_binary(token) and token != "" ->
        fetch(state, token: token)

      _missing ->
        Logger.warning("allowed_contributors refresh_skipped source=file reason=missing_github_token; intake defers until a token is available")
        state
    end
  end

  defp fetch(state, opts),
    do: state.owner |> Source.fetch(state.repo, Keyword.put(opts, :request_fun, state.request_fun)) |> apply_fetch(state)

  defp apply_fetch({:error, reason}, state) do
    Logger.warning("allowed_contributors refresh_failed reason=#{inspect(reason)}")
    state
  end

  defp apply_fetch({:ok, snapshot}, state) do
    {sha, entries} = describe(snapshot)
    source = Source.label(snapshot)

    if sha != state.ledger.sha or entries != state.ledger.entries or source != state.ledger.allowlist_source,
      do: alert_change(state, snapshot, sha, entries)

    Logger.info("allowed_contributors refreshed source=#{source || "file@absent"}")
    ledger = Ledger.put_allowlist(state.ledger, sha, entries, source)
    _ = Ledger.save(ledger, state.ledger_path)
    %{state | snapshot: snapshot, ledger: ledger}
  end

  defp describe(:absent), do: {nil, []}
  defp describe(%{sha: sha, allowlist: {:invalid, _reason}}), do: {sha, ["invalid"]}
  defp describe(%{sha: sha, allowlist: list}), do: {sha, AllowList.diff(AllowList.empty(), list).added}

  defp alert_change(state, %{allowlist: {:invalid, reason}} = snapshot, _sha, _entries) do
    state.alert_fun.(
      "allowed_contributors.invalid",
      "#{Source.label(snapshot)} does not parse (#{inspect(reason)}); allowed-contributor intake admits nobody until it is fixed.",
      reason: "Malformed allow-list fails closed",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp alert_change(state, snapshot, _sha, entries) do
    added = entries -- state.ledger.entries
    removed = state.ledger.entries -- entries

    state.alert_fun.(
      "allowed_contributors.changed",
      "Allowed contributors changed (#{state.ledger.allowlist_source || "none"} -> #{Source.label(snapshot) || "file@absent"}): " <>
        "added #{inspect(added)}, removed #{inspect(removed)}.",
      reason: "Allowed-contributor trust set changed; confirm the change was intended",
      needs_attention: true,
      severity: "warning"
    )
  end
end

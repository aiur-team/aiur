defmodule Aiur.Ownership.CLI do
  @moduledoc """
  `aiur ticket owner|assign`: show and transfer a ticket's ownership record.

  Both verbs return an exit code (0, 64 refusal, 75 outcome unknown). Everything they touch is an
  injectable option (`:read_fun`, `:transfer_fun`, `:liveness_fun`, `:identity_fun`, `:open_pr_fun`,
  `:disable_fun`, `:repo`, `:now`) so the tests never reach GitHub or the store.

  A transfer to a peer needs the peer's `daemon_key` and project list from `PeerState` (`:peer_fun`); a
  fresh list that lacks the repo refuses (64), an unknown or stale one warns and writes.
  """

  alias Aiur.Gateway.Identity, as: GatewayIdentity
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.LandingWithdrawal
  alias Aiur.Orchestrator.ReworkGate
  alias Aiur.Ownership.{Delegation, GitHubRef, Liveness, PeerState}

  @ticket ~r/\A(pr-)?[1-9][0-9]{0,9}\z/

  @spec owner(keyword()) :: 0 | 64 | 75
  def owner(opts) do
    case ticket(opts) do
      {:ok, ticket} ->
        case read(ticket, opts) do
          {:ok, observed} -> show(ticket, observed, opts)
          {:unknown, reason} -> unknown_read(ticket, reason, opts)
        end

      {:error, message} ->
        refuse(opts, message)
    end
  end

  @spec assign(keyword()) :: 0 | 64 | 75
  def assign(opts) do
    with {:ok, ticket} <- ticket(opts),
         {:ok, note} <- note(opts),
         {:ok, target} <- target(opts),
         {:ok, observed} <- read_or_fail(ticket, opts),
         {:ok, record} <- owned(observed, ticket),
         :ok <- check_liveness(record, target, opts) do
      transfer(ticket, observed, record, target, note, opts)
    else
      {:error, message} -> refuse(opts, message)
      {:unknown, message} -> unknown(opts, message)
    end
  end

  # -- owner ---------------------------------------------------------------

  defp show(ticket, %{record: nil}, opts), do: print(opts, base(ticket, "unowned", opts), "##{ticket} has no owner record")

  defp show(ticket, %{record: %{state: "released"} = record}, opts) do
    map = base(ticket, "released", opts) |> Map.merge(%{epoch: record.epoch, reason: record.reason, at: record.at})
    print(opts, map, "##{ticket} released at epoch #{record.epoch} (#{age_text(record, opts)})")
  end

  defp show(ticket, %{record: record}, opts) do
    liveness = liveness(record, opts)
    map = base(ticket, "owned", opts) |> Map.merge(record_map(record, opts)) |> Map.put(:liveness, liveness_map(liveness))

    text =
      "##{ticket} owned by #{record.gateway_label} (#{record.gateway_id}) daemon #{record.daemon_key}\n" <>
        "epoch #{record.epoch} (previous #{record.previous_epoch}), #{record.reason} by #{record.actor.kind}:#{record.actor.id}, " <>
        "#{age_text(record, opts)} (#{record.at})\n" <>
        "liveness: #{liveness_text(liveness)}"

    print(opts, map, text)
  end

  # A failed read is never rendered as unowned or zero.
  defp unknown_read(ticket, reason, opts) do
    map = Map.merge(base(ticket, "unknown", opts), %{freshness: "unknown", owner: nil, epoch: nil, liveness: nil})
    print(opts, map, "##{ticket} ownership unknown: read failed (#{inspect(reason)})", 75)
  end

  defp base(ticket, state, opts) do
    %{schema: "aiur.ticket-owner/v1", ticket: ticket, repo: repo(opts), observed_at: iso(now(opts)), freshness: "fresh", state: state, owner: nil, epoch: nil, liveness: nil}
  end

  defp record_map(record, opts) do
    %{
      owner: %{gateway_id: record.gateway_id, gateway_label: record.gateway_label, daemon_key: record.daemon_key},
      epoch: record.epoch,
      previous_epoch: record.previous_epoch,
      reason: record.reason,
      note: record.note,
      actor: record.actor,
      at: record.at,
      age_ms: age_ms(record, opts)
    }
  end

  defp liveness_map(%{status: status, source: source, age_ms: age}), do: %{status: status, source: source || "unknown", age_ms: age}

  defp liveness_text(%{status: status, source: source, age_ms: age}) do
    "#{status}#{if source, do: " via #{source}", else: " (no liveness source)"}#{if age, do: ", last heartbeat #{div(age, 1000)}s ago", else: ""}"
  end

  defp age_text(record, opts), do: "#{div(age_ms(record, opts), 1000)}s ago"

  defp age_ms(record, opts) do
    {:ok, at, _} = DateTime.from_iso8601(record.at)
    max(DateTime.diff(now(opts), at, :millisecond), 0)
  end

  # -- assign --------------------------------------------------------------

  defp note(opts) do
    reason = opts[:reason]

    cond do
      not (is_binary(reason) and String.trim(reason) != "") -> {:error, "--reason is required (1..500 characters)"}
      String.length(reason) > 500 or String.match?(reason, ~r/[[:cntrl:]]/) -> {:error, "--reason must be 1..500 characters without controls"}
      opts[:force] == true -> {:ok, String.slice("forced: " <> reason, 0, 500)}
      true -> {:ok, reason}
    end
  end

  defp target(opts) do
    to = opts[:to]
    identity = Keyword.get(opts, :identity_fun, &identity/0).()

    cond do
      not is_binary(to) or to == "" -> {:error, "--to <gateway> is required"}
      is_nil(identity.gateway_id) -> {:error, "gateway identity unavailable; cannot assign"}
      String.downcase(to) in [String.downcase(identity.gateway_label || ""), identity.gateway_id] -> {:ok, identity}
      true -> peer_target(to, opts)
    end
  end

  # A peer is judged on its project list before anything is written. Unknown evidence only warns.
  defp peer_target(to, opts) do
    case Keyword.get(opts, :peer_fun, &PeerState.peer/1).(to) do
      nil ->
        {:error, "unknown gateway #{inspect(to)}; no project list or daemon key cached for it; read it first: aiur gateway status #{to}"}

      peer ->
        list = if peer.projects && peer.observed_at, do: %{projects: peer.projects, observed_at: peer.observed_at}
        warn(opts, Delegation.check_target(list, repo(opts), to, now(opts)), peer)
    end
  end

  defp warn(_opts, {:refuse, message}, _peer), do: {:error, message}

  defp warn(opts, check, peer) do
    with {:warn, message} <- check, do: Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).("aiur: warning: #{message}")

    if is_binary(peer.daemon_key),
      do: {:ok, %{gateway_id: peer.gateway_id, gateway_label: peer.label, daemon_key: peer.daemon_key, peer: true}},
      else: {:error, "#{peer.label || peer.gateway_id}'s daemon key is unknown; nothing written"}
  end

  defp identity do
    key =
      case Aiur.Identity.instance_key() do
        {:ok, key} -> key
        _ -> nil
      end

    Map.put(GatewayIdentity.current(), :daemon_key, key)
  end

  defp read_or_fail(ticket, opts) do
    case read(ticket, opts) do
      {:ok, observed} -> {:ok, observed}
      {:unknown, reason} -> {:unknown, "ownership read failed (#{inspect(reason)}); nothing written. Retry the same command."}
    end
  end

  defp owned(%{record: %{state: "owned"} = record}, _ticket), do: {:ok, record}
  defp owned(_observed, ticket), do: {:error, "##{ticket} has no current owner; it is claimed when dispatched"}

  # Already owned by the target: idempotent retry, no liveness question.
  defp check_liveness(record, target, opts) do
    if same_owner?(record, target), do: :ok, else: check_owner_liveness(record, opts)
  end

  defp check_owner_liveness(record, opts) do
    force? = opts[:force] == true

    case liveness(record, opts) do
      _ when force? -> :ok
      %{status: :offline} -> :ok
      %{status: :online} -> {:error, "owner is online; ask it to release"}
      %{status: :unknown} -> {:error, "owner liveness unknown; treat as online"}
    end
  end

  # Self is {gateway_id, daemon_key}, as in the dispatch gate; another daemon on this gateway is not self.
  defp same_owner?(record, target), do: record.gateway_id == target.gateway_id and record.daemon_key == target.daemon_key

  defp transfer(ticket, observed, record, target, note, opts) do
    if same_owner?(record, target) do
      finish(ticket, record, record.epoch - 1, opts, true)
    else
      new_owner = %{gateway_id: target.gateway_id, gateway_label: target.gateway_label, daemon_key: target.daemon_key, actor: actor(opts), note: note}

      case Keyword.get(opts, :transfer_fun, &GitHubRef.transfer/4).(repo(opts), ticket, observed, new_owner) do
        {:won, new} ->
          delegated(ticket, new, target, opts)
          finish(ticket, new, record.epoch, opts, false)

        {:lost, current} ->
          refuse(opts, "ownership changed to #{current.gateway_label} at epoch #{current.epoch}; re-read with aiur ticket owner")

        {:unknown, reason} ->
          unknown(opts, "transfer outcome unknown (#{inspect(reason)}); retry: aiur ticket assign #{ticket} --to #{opts[:to]} --reason <text>")
      end
    end
  end

  # The delegator is not in the ref, so the transfer is remembered locally for the waiting-label pass.
  defp delegated(ticket, new, %{peer: true}, opts) do
    Keyword.get(opts, :delegation_fun, &PeerState.add_delegation/1).(%{repo: repo(opts), ticket: ticket, gateway_id: new.gateway_id, epoch: new.epoch, at: iso(now(opts))})
    :ok
  end

  defp delegated(_ticket, _new, _target, _opts), do: :ok

  # Auto-merge is disabled only after the transfer is on record, so a failure here never leaves it
  # off on a ticket the old owner still holds; the transfer stands and the retry is safe.
  defp finish(ticket, record, previous_epoch, opts, retry?) do
    {auto_merge, code} = disable_auto_merge(ticket, opts)
    map = base(ticket, "owned", opts) |> Map.merge(record_map(record, opts)) |> Map.merge(%{previous_epoch: previous_epoch, auto_merge: auto_merge, forced: opts[:force] == true})
    verb = if retry?, do: "already owned by", else: "transferred to"
    print(opts, map, "##{ticket} #{verb} #{record.gateway_label} at epoch #{record.epoch}; auto-merge: #{auto_merge}", code)
  end

  defp disable_auto_merge(ticket, opts) do
    case Keyword.get(opts, :open_pr_fun, &ReworkGate.open_pr/1).(ticket) do
      {:skip, :no_open_pr} -> {"none", 0}
      {:ok, %{"number" => number}} -> disable(number, opts)
      {:ok, _} -> {"failed: pull request has no number", 75}
      {:error, reason} -> {"failed: #{inspect(reason)}", 75}
    end
  end

  defp disable(number, opts) do
    case Keyword.get(opts, :disable_fun, &LandingWithdrawal.disable_auto_merge/1).(number) do
      {:ok, _actions} -> {"disabled", 0}
      {:error, reason, _actions} -> {"failed: #{inspect(reason)}", 75}
      {:error, reason} -> {"failed: #{inspect(reason)}", 75}
    end
  end

  defp actor(opts) do
    case opts[:as] do
      id when is_binary(id) -> %{kind: "executor", id: id}
      _ -> %{kind: "human", id: "cli:#{System.get_env("USER", "unknown")}"}
    end
  end

  # -- shared --------------------------------------------------------------

  defp ticket(opts) do
    id = opts[:ticket]
    if is_binary(id) and Regex.match?(@ticket, id), do: {:ok, id}, else: {:error, "ticket must be a positive number or pr-<n>"}
  end

  defp read(ticket, opts), do: Keyword.get(opts, :read_fun, &GitHubRef.read/2).(repo(opts), ticket)

  defp liveness(record, opts) do
    case opts[:liveness_fun] do
      fun when is_function(fun, 1) ->
        fun.(record)

      nil ->
        identity = Keyword.get(opts, :identity_fun, &identity/0).()
        self_fun = fn -> record.gateway_id == identity.gateway_id and record.daemon_key == identity.daemon_key end
        Liveness.classify(record, Liveness.gather(record, self_fun: self_fun), Liveness.offline_after_ms())
    end
  end

  defp repo(opts), do: Keyword.get_lazy(opts, :repo, &GitHubConfig.repo/0)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
  defp iso(dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp print(opts, map, text, code \\ 0) do
    IO.puts(if opts[:json], do: Jason.encode!(Aiur.JSONSafe.normalize(map)), else: text)
    code
  end

  defp refuse(opts, message), do: fail(opts, message, 64)
  defp unknown(opts, message), do: fail(opts, message, 75)

  defp fail(opts, message, code) do
    Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).("aiur: #{message}")
    code
  end
end

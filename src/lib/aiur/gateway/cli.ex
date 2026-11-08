defmodule Aiur.Gateway.Cli do
  @moduledoc """
  `aiur gateway permissions|grant|revoke|trust`: edit and inspect this gateway's own `allows` grants.

  Every function runs on this gateway only. `grant`, `revoke` and `trust` are refused over
  `/api/v1/control` (`Aiur.ControlCall` answers `grants_are_local`), and nothing here is in the allowlist.
  `read` is written at once; a write category raises a human-required `gateway_grant` Decision that
  `Aiur.Gateway.GrantConfirmation` writes only after a signed-in human approves.
  """

  import Aiur.ControlCLI.Protocol, only: [control_error: 1, exit_marker: 1, guarded: 2]

  alias Aiur.ClientTokens
  alias Aiur.ControlCall.Audit
  alias Aiur.Gateway.{Discovery, GrantRequest, Registry, Status}

  @actor "cli_local"

  @spec permissions(keyword()) :: :ok
  def permissions(opts \\ []), do: guarded("gateway permissions", fn -> opts |> do_permissions() |> exit_marker() end)

  @spec grant(keyword()) :: :ok
  def grant(opts), do: guarded("gateway grant", fn -> opts |> do_grant(Keyword.get(opts, :categories, [])) |> exit_marker() end)

  @spec trust(keyword()) :: :ok
  def trust(opts) do
    guarded("gateway trust", fn ->
      code = if opts[:full] == true, do: do_grant(opts, Registry.categories()), else: fail("gateway trust requires --full", 64)
      exit_marker(code)
    end)
  end

  @doc "One row per registry entry from the launcher's `agents --json` results (`:data`); an unreachable entry shows its cached last answer with its age."
  @spec list(keyword()) :: :ok
  def list(opts \\ []), do: guarded("gateway list", fn -> opts |> Keyword.delete(:peer) |> Status.run() |> exit_marker() end)

  @spec status(keyword()) :: :ok
  def status(opts), do: guarded("gateway status", fn -> opts |> Status.run() |> exit_marker() end)

  @doc "Lists registry entries and tailnet peers that answer hello. Read-only; `--json` rows carry `observed_at`, `age_ms: 0`, `freshness`."
  @spec discover(keyword()) :: :ok
  def discover(opts \\ []) do
    guarded("gateway discover", fn ->
      result = Discovery.discover(Keyword.take(opts, [:port, :http_get, :tailscale_executable, :tailscale_runner]))
      print_discovery(result, opts[:json])
      exit_marker(0)
    end)
  end

  defp print_discovery(result, true) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    rows = Enum.map(result.rows, &Map.merge(&1, %{observed_at: now, age_ms: 0, freshness: "current"}))
    IO.puts(Jason.encode!(%{tailscale_found: result.tailscale_found, gateways: rows}))
  end

  defp print_discovery(result, _json) do
    unless result.tailscale_found, do: IO.puts("Tailscale not found; showing registered gateways only")
    IO.puts("name\tstatus\tgateway_id\turl")
    Enum.each(result.rows, &IO.puts("#{&1.name}\t#{&1.status}\t#{&1.gateway_id || "-"}\t#{&1.url}"))
  end

  @spec revoke(keyword()) :: :ok
  def revoke(opts), do: guarded("gateway revoke", fn -> opts |> do_revoke() |> exit_marker() end)

  defp do_grant(opts, categories) do
    with :ok <- check_categories(categories),
         {:ok, peer} <- find(opts[:peer]) do
      add_read(peer, categories) |> request_rest(peer, opts)
    else
      {:error, {code, message}} -> fail(message, code)
    end
  end

  defp check_categories([]), do: {:error, {64, "grant requires at least one category"}}

  defp check_categories(categories) do
    cond do
      "trust" in categories -> {:error, {64, "trust is not a grantable category"}}
      bad = Enum.find(categories, &(&1 not in Registry.categories())) -> {:error, {64, "unknown category #{bad}; use #{Enum.join(Registry.categories(), ", ")}"}}
      true -> :ok
    end
  end

  defp add_read(peer, categories) do
    if "read" in categories and "read" not in peer.categories do
      case update(peer, &Enum.uniq(&1 ++ ["read"]), @actor) do
        :ok -> IO.puts("Granted read to #{label(peer)}.")
        {:error, reason} -> control_error("could not write #{Registry.path()}: #{inspect(reason)}")
      end
    end

    categories -- ["read"]
  end

  defp request_rest([], _peer, _opts), do: 0

  defp request_rest(pending, peer, opts) do
    pending = pending -- peer.categories

    if pending == [] do
      IO.puts("#{label(peer)} already holds that grant.")
      0
    else
      raise_decision(peer, pending, opts)
    end
  end

  defp raise_decision(peer, pending, opts) do
    case GrantRequest.request(peer, pending, Keyword.take(opts, [:store])) do
      {:ok, decision} ->
        audit("grant_requested", peer, %{categories: pending, decision_id: decision.decision_id, actor: @actor})
        IO.puts("Pending: #{Enum.join(pending, ", ")} for #{label(peer)}. Decision #{decision.decision_id} is open.")
        IO.puts("Confirm it on the dashboard signed in with Google or a passkey; a client token cannot.")
        IO.puts("Or edit #{Registry.path()} by hand: set allows.categories to include #{Enum.join(pending, ", ")}.")
        0

      {:error, reason} ->
        fail("cannot raise the grant Decision (#{inspect(reason)}); hand edit #{Registry.path()} instead", 1)
    end
  end

  defp do_revoke(opts) do
    case {find(opts[:peer]), Keyword.get(opts, :categories, [])} do
      {{:ok, peer}, []} -> revoke_peer(peer)
      {{:ok, peer}, categories} -> revoke_categories(peer, categories)
      {{:error, {code, message}}, _categories} -> fail(message, code)
    end
  end

  defp revoke_categories(peer, categories) do
    case update(peer, &(&1 -- categories), @actor) do
      :ok ->
        audit("grant_revoked", peer, %{categories: categories, actor: @actor})
        IO.puts("Revoked #{Enum.join(categories, ", ")} from #{label(peer)}.")
        0

      {:error, reason} ->
        fail("could not write #{Registry.path()}: #{inspect(reason)}", 1)
    end
  end

  # Blocking the peer first is fail-closed: a token that cannot be deleted still hits the empty category list.
  defp revoke_peer(peer) do
    case update(peer, fn _ -> [] end, @actor, clear_credentials: true) do
      :ok -> revoke_tokens(peer)
      {:error, reason} -> fail("could not write #{Registry.path()}: #{inspect(reason)}", 1)
    end
  end

  defp revoke_tokens(peer) do
    audit("grant_revoked", peer, %{categories: peer.categories, actor: @actor})
    names = (token_names(peer) ++ peer.credentials) |> Enum.uniq()
    failed = Enum.reject(names, &(ClientTokens.revoke(&1) in [:ok, {:error, :not_found}]))
    Enum.each(names -- failed, &audit("token_revoked", peer, %{token: &1, actor: @actor}))
    IO.puts("Revoked every grant from #{label(peer)} and #{length(names) - length(failed)} client token(s).")

    if failed == [], do: 0, else: fail("could not revoke token(s): #{Enum.join(failed, ", ")}; the peer is already blocked", 1)
  end

  defp token_names(peer) do
    case ClientTokens.list_for_peer(peer.gateway_id) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  defp update(peer, fun, actor, opts \\ []) do
    Registry.write(
      fn instances ->
        Map.new(instances, fn
          {name, %{"gateway_id" => id} = entry} when id == peer.gateway_id -> {name, put_allows(entry, fun, opts)}
          other -> other
        end)
      end,
      actor
    )
  end

  defp put_allows(entry, fun, opts) do
    allows = Map.get(entry, "allows") || %{}
    allows = Map.put(allows, "categories", fun.(Map.get(allows, "categories", ["read"])))
    Map.put(entry, "allows", if(opts[:clear_credentials], do: Map.delete(allows, "credentials"), else: allows))
  end

  defp find(selector) when is_binary(selector) do
    case Registry.get() do
      {:ok, %{peers: peers}} -> peers |> Map.values() |> match(selector) |> pick(selector)
      {:error, reason} -> {:error, {1, "gateway registry unavailable: #{inspect(reason)}"}}
    end
  end

  defp find(_selector), do: {:error, {64, "a peer name, label or gateway id is required"}}

  defp match(peers, selector) do
    down = String.downcase(selector)
    Enum.filter(peers, &(&1.name == selector or String.downcase(&1.label || "") == down or String.downcase(&1.gateway_id || "") == down))
  end

  defp pick([%{gateway_id: nil}], selector), do: {:error, {64, "peer #{selector} has no gateway_id; pin one in #{Registry.path()} first"}}
  defp pick([peer], _selector), do: {:ok, peer}
  defp pick([], selector), do: {:error, {66, "no such peer: #{selector}"}}
  defp pick(many, selector), do: {:error, {64, "peer #{selector} is ambiguous: #{Enum.map_join(many, ", ", & &1.name)}"}}

  defp do_permissions(opts) do
    case Registry.get() do
      {:ok, view} -> show(view, opts)
      {:error, reason} -> fail("gateway registry unavailable: #{inspect(reason)}", 1)
    end
  end

  defp show(view, opts) do
    peers = view.peers |> Map.values() |> Enum.sort_by(& &1.name) |> filter(opts[:peer])
    pending = pending_decisions(opts)
    {observed_at, age_ms} = observed()

    if opts[:json] do
      rows = Enum.map(peers, &Map.put(&1, :pending, Map.get(pending, &1.gateway_id, [])))
      body = %{observed_at: observed_at, age_ms: age_ms, freshness: if(observed_at, do: "current", else: "unknown"), last_error: view.last_error && inspect(view.last_error), peers: rows}
      IO.puts(Jason.encode!(body))
    else
      if view.last_error, do: IO.puts("registry rejected, last good in force: #{inspect(view.last_error)}")
      IO.puts("name\tlabel\tgateway_id\tcategories\tcredentials\tpending")
      Enum.each(peers, &IO.puts(row(&1, pending)))
      if opts[:peer] && peers != [], do: Enum.each(history(hd(peers)), &IO.puts("audit: " <> &1))
    end

    if peers == [] and opts[:peer], do: 66, else: 0
  end

  defp filter(peers, nil), do: peers
  defp filter(peers, selector), do: Enum.filter(peers, &(&1.name == selector or &1.label == selector or &1.gateway_id == selector))

  defp row(peer, pending) do
    id = peer.gateway_id
    Enum.join([peer.name, peer.label, id && String.slice(id, 0, 8), Enum.join(peer.categories, ","), length(peer.credentials), Enum.join(Map.get(pending, id, []), ",")], "\t")
  end

  defp observed do
    case File.stat(Registry.path(), time: :posix) do
      {:ok, %{mtime: mtime}} -> {DateTime.from_unix!(mtime) |> DateTime.to_iso8601(), max(System.system_time(:millisecond) - mtime * 1000, 0)}
      {:error, _reason} -> {nil, nil}
    end
  end

  defp pending_decisions(opts) do
    Aiur.DecisionStore.list(Keyword.get(opts, :store, Aiur.Commands.default_store()))
    |> Enum.filter(&(&1.kind == "gateway_grant" and &1.decision_status == :open))
    |> Enum.reduce(%{}, fn decision, acc ->
      case GrantRequest.parse(decision.source_id) do
        {:ok, peer_id, _categories, _digest} -> Map.update(acc, peer_id, [decision.decision_id], &[decision.decision_id | &1])
        :error -> acc
      end
    end)
  catch
    :exit, _reason -> %{}
  end

  defp history(peer) do
    path = Audit.audit_file()

    if peer.gateway_id && File.exists?(path) do
      path |> File.stream!() |> Stream.filter(&String.contains?(&1, peer.gateway_id)) |> Enum.take(-5) |> Enum.map(&String.trim/1)
    else
      []
    end
  end

  defp audit(event, peer, extra) do
    Audit.append(Map.merge(%{at: DateTime.utc_now() |> DateTime.to_iso8601(), event: event, peer: peer.gateway_id, name: peer.name}, extra))
  end

  defp label(peer), do: peer.label || peer.name

  defp fail(message, code) do
    control_error("aiur: " <> message)
    code
  end
end

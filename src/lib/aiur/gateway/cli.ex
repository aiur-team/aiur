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
  alias Aiur.Gateway.{Discovery, GrantRequest, Hello, Identity, Invites, Registry}

  @actor "cli_local"
  @overlap_seconds 600

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

  @doc """
  Prints one `aiur-invite:` code for this gateway. Local only; the grants live in the invite record, not the code.
  Options: `categories`, `ttl` (seconds), `url` (else `server.public_url`), `tls_pin` (else `server.tls_pin_sha256`).
  """
  @spec invite(keyword()) :: :ok
  def invite(opts), do: guarded("gateway invite", fn -> opts |> do_invite() |> exit_marker() end)

  defp do_invite(opts) do
    grants = Enum.uniq(["read" | Keyword.get(opts, :categories, [])])
    pin = opts[:tls_pin] || Hello.tls_pin()

    with :ok <- check_categories(grants),
         {:ok, url} <- invite_url(opts[:url] || public_url()),
         :ok <- check_pin(pin),
         %{gateway_id: id} when is_binary(id) <- Identity.current() || {:error, {1, "this gateway has no identity yet"}},
         {:ok, invite} <- Invites.create(grants, Keyword.get(opts, :ttl, Invites.default_ttl())) do
      if is_nil(pin), do: control_error("warning: no TLS pin; the joiner will trust whatever certificate answers at #{url}")
      payload = %{v: 1, url: url, gateway_id: id, fp: pin, id: invite.id, secret: invite.secret, exp: invite.exp}
      IO.puts("aiur-invite:" <> Base.url_encode64(Jason.encode!(payload), padding: false))
      audit("invite_created", %{gateway_id: id, name: invite.id}, %{categories: grants, exp: invite.exp, actor: @actor})
      0
    else
      {:error, {code, message}} -> fail(message, code)
      {:error, :invalid_ttl} -> fail("--ttl must be between 1 second and #{Invites.max_ttl()} seconds", 64)
      {:error, reason} -> fail("could not create the invite: #{inspect(reason)}", 1)
      _unavailable -> fail("this gateway has no identity yet", 1)
    end
  end

  defp public_url do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings.server.public_url
      _unavailable -> nil
    end
  end

  defp invite_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and is_binary(host) and host != "" -> {:ok, String.trim_trailing(url, "/")}
      _invalid -> {:error, {64, "--url must be an absolute http(s) URL"}}
    end
  end

  defp invite_url(_none), do: {:error, {64, "set server.public_url or pass --url so the joiner can reach this gateway"}}

  defp check_pin(nil), do: :ok
  defp check_pin(pin), do: if(Regex.match?(~r/\A[0-9a-f]{64}\z/, pin), do: :ok, else: {:error, {64, "--tls-pin must be 64 lowercase hex characters"}})

  @doc "Deletes the registry entry for a peer and revokes every client token bound to it. Local only."
  @spec remove(keyword()) :: :ok
  def remove(opts), do: guarded("gateway remove", fn -> opts |> do_remove() |> exit_marker() end)

  defp do_remove(opts) do
    case registered(opts[:peer]) do
      {:ok, peer} -> remove_peer(peer)
      {:error, {code, message}} -> fail(message, code)
    end
  end

  defp remove_peer(peer) do
    names = token_names(peer) |> Enum.concat(peer.credentials) |> Enum.uniq()

    case Registry.write(&Map.delete(&1, peer.name), @actor) do
      :ok ->
        Enum.each(names, &ClientTokens.revoke/1)
        audit("peer_removed", peer, %{tokens: names, actor: @actor})
        IO.puts("Removed #{label(peer)} and #{length(names)} client token(s).")
        0

      {:error, reason} ->
        fail("could not write #{Registry.path()}: #{inspect(reason)}", 1)
    end
  end

  # A manually registered peer may have no gateway_id, so remove also matches the instance name.
  defp registered(selector) do
    with {:ok, %{peers: peers}} <- Registry.get(), %{} = peer <- Map.get(peers, selector) do
      {:ok, peer}
    else
      {:error, reason} -> {:error, {1, "gateway registry unavailable: #{inspect(reason)}"}}
      _by_name_missed -> find(selector)
    end
  end

  @doc "Mints a new token for a peer; the old one stays valid for 10 minutes, then is revoked. Prints the new token once."
  @spec rotate(keyword()) :: :ok
  def rotate(opts), do: guarded("gateway rotate", fn -> opts |> do_rotate() |> exit_marker() end)

  defp do_rotate(opts) do
    with {:ok, peer} <- find(opts[:peer]),
         {:ok, [_ | _] = old} <- peer_tokens(peer),
         current = Enum.max_by(old, &generation(&1["name"], peer)),
         name = "peer-#{peer.name}-#{generation(current["name"], peer) + 1}",
         {:ok, token} <- ClientTokens.create(name, current["scope"], peer: peer.gateway_id, categories: current["categories"]),
         :ok <- ClientTokens.expire(current["name"], DateTime.utc_now() |> DateTime.add(@overlap_seconds) |> DateTime.to_iso8601()),
         :ok <- add_credential(peer, current["name"], name) do
      Task.start(fn ->
        Process.sleep(@overlap_seconds * 1000)
        finish_rotation(peer.gateway_id, current["name"])
      end)

      audit("token_rotated", peer, %{token: name, old: current["name"], actor: @actor})
      IO.puts("New token for #{label(peer)} (shown once; the old one works for 10 minutes):")
      IO.puts(token)
      IO.puts("Give it to the peer with: aiur gateway register #{peer.name} --url <url> --token-file <file>")
      0
    else
      {:ok, []} -> fail("#{label_of(opts)} has no client token to rotate", 66)
      {:error, {code, message}} -> fail(message, code)
      {:error, reason} -> fail("could not rotate: #{inspect(reason)}", 1)
    end
  end

  defp label_of(opts), do: opts[:peer]

  defp peer_tokens(peer) do
    with {:ok, tokens} <- ClientTokens.list(), do: {:ok, Enum.filter(tokens, &(&1["peer"] == peer.gateway_id))}
  end

  defp generation(name, peer) do
    prefix = "peer-#{peer.name}-"

    with true <- String.starts_with?(name, prefix),
         {n, ""} <- name |> String.replace_prefix(prefix, "") |> Integer.parse() do
      n
    else
      _manual -> 0
    end
  end

  defp add_credential(peer, old, new) do
    Registry.write(
      fn instances ->
        Map.new(instances, fn
          {name, %{"gateway_id" => id} = entry} when id == peer.gateway_id ->
            allows = Map.get(entry, "allows") || %{}
            {name, Map.put(entry, "allows", Map.put(allows, "credentials", Enum.uniq(Map.get(allows, "credentials", []) ++ [old, new])))}

          other ->
            other
        end)
      end,
      @actor
    )
  end

  @doc false
  @spec finish_rotation(String.t(), String.t()) :: :ok | {:error, term()}
  def finish_rotation(peer_id, old) do
    ClientTokens.revoke(old)

    Registry.write(
      fn instances ->
        Map.new(instances, fn
          {name, %{"gateway_id" => ^peer_id, "allows" => %{"credentials" => names} = allows} = entry} -> {name, %{entry | "allows" => %{allows | "credentials" => names -- [old]}}}
          other -> other
        end)
      end,
      @actor
    )
  end

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

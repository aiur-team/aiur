defmodule Aiur.Ownership.MigrateCLI do
  @moduledoc """
  `aiur ownership migrate --map <prefix>=<gateway> ... [--apply] [--json]`.

  Without `--apply` nothing is written. Only this gateway can be a target until the peer registry
  exists (a claim needs the target's `daemon_key`), so a `--map` naming another gateway exits 64
  before any read. Exit codes: 0, 64 refusal, 75 a read failed or a claim outcome is unknown.
  Injectable: `:list_fun`, `:owners_fun`, `:claim_fun`, `:identity_fun`, `:repo`, `:error_fun`.
  """

  alias Aiur.Gateway.Identity, as: GatewayIdentity
  alias Aiur.GitHub.{Access, Config, Issues.LabelPages}
  alias Aiur.Ownership.{GitHubRef, Migration}

  @spec run(keyword()) :: 0 | 64 | 75
  def run(opts) do
    with {:ok, map} <- parse_maps(opts[:maps]),
         {:ok, identity} <- resolve(map, opts),
         {:ok, tickets} <- list(opts),
         {:ok, owners} <- owners(opts) do
      actions = tickets |> Enum.map(&Map.put(&1, :owner, Map.get(owners, &1.ticket))) |> Migration.plan(map)
      report(actions, identity, opts)
    else
      {:error, message} -> fail(opts, message, 64)
      {:unknown, message} -> fail(opts, message, 75)
    end
  end

  defp report(actions, identity, opts) do
    if opts[:apply] == true do
      claim = Keyword.get(opts, :claim_fun) || default_claim(identity, opts)
      result = Migration.apply(actions, claim_fun: claim)
      print(opts, result, Map.put(summary(actions), :applied, true), result, if(result.unknown > 0, do: 75, else: 0))
    else
      print(opts, nil, Map.put(summary(actions), :applied, false), nil, 0)
    end
  end

  defp summary(actions) do
    counts = Enum.frequencies_by(actions, &elem(&1, 0))
    %{claim: counts[:claim] || 0, already: counts[:already] || 0, conflict: counts[:conflict] || 0, ambiguous: counts[:ambiguous] || 0, skip: counts[:skip] || 0, writes: 0}
  end

  defp print(opts, result, plan, _result, code) do
    out = if result, do: Map.merge(plan, %{writes: result.writes, result: result}), else: plan
    text = "plan: #{plan.claim} claim, #{plan.already} already, #{plan.conflict} conflict, #{plan.ambiguous} ambiguous, #{plan.skip} skip\nwrites: #{out.writes}"
    IO.puts(if opts[:json], do: Jason.encode!(Aiur.JSONSafe.normalize(out)), else: text)
    code
  end

  defp parse_maps(maps) when is_list(maps) and maps != [] do
    Enum.reduce_while(maps, {:ok, %{}}, fn entry, {:ok, acc} ->
      case String.split(to_string(entry), "=", parts: 2) do
        [prefix, gateway] when prefix != "" and gateway != "" -> {:cont, {:ok, Map.put(acc, prefix, gateway)}}
        _ -> {:halt, {:error, "--map expects <prefix>=<gateway>, got #{inspect(entry)}"}}
      end
    end)
  end

  defp parse_maps(_), do: {:error, "at least one --map <prefix>=<gateway> is required"}

  defp resolve(map, opts) do
    identity = Keyword.get_lazy(opts, :identity_fun, fn -> &identity/0 end).()
    local = [identity.gateway_label, identity.gateway_id] |> Enum.reject(&is_nil/1) |> Enum.map(&String.downcase/1)

    cond do
      is_nil(identity.gateway_id) -> {:error, "gateway identity unavailable; cannot migrate"}
      bad = Enum.find(Map.values(map), &(String.downcase(&1) not in local)) -> {:error, "unknown gateway #{inspect(bad)}; only this gateway (#{identity.gateway_label}) can be targeted"}
      true -> {:ok, identity}
    end
  end

  defp identity do
    key = with {:ok, key} <- Aiur.Identity.instance_key(), do: key
    Map.put(GatewayIdentity.current(), :daemon_key, if(is_binary(key), do: key))
  end

  defp list(opts) do
    case Keyword.get(opts, :list_fun) || (&list_open/0) do
      fun when is_function(fun, 0) -> fun.() |> wrap("open-issue listing failed")
    end
  end

  defp list_open do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"

      with {:ok, issues} <- LabelPages.fetch_label_issue_pages(&Access.default_request_fun/1, url, token, owner, repo, Config.label_prefix(), []) do
        {:ok, Enum.map(issues, &%{ticket: &1.identifier, labels: &1.labels || []})}
      end
    end
  end

  defp owners(opts) do
    fun = Keyword.get(opts, :owners_fun) || fn -> GitHubRef.list_owned(repo(opts)) end

    case fun.() do
      {:ok, entries} -> {:ok, for({ticket, {:ok, %{record: record}}} <- entries, record, into: %{}, do: {ticket, record})}
      other -> wrap(other, "ownership listing failed")
    end
  end

  defp wrap({:ok, _} = ok, _), do: ok
  defp wrap({:error, reason}, what), do: {:unknown, "#{what} (#{inspect(reason)}); nothing written"}
  defp wrap({:unknown, reason}, what), do: {:unknown, "#{what} (#{inspect(reason)}); nothing written"}

  defp default_claim(identity, opts) do
    claimant = %{
      gateway_id: identity.gateway_id,
      gateway_label: identity.gateway_label,
      daemon_key: identity.daemon_key,
      actor: %{kind: "human", id: "cli:#{System.get_env("USER", "unknown")}"},
      reason: "migration"
    }

    fn ticket, _gateway -> GitHubRef.claim(repo(opts), ticket, claimant) end
  end

  defp repo(opts), do: Keyword.get_lazy(opts, :repo, &Config.repo/0)

  defp fail(opts, message, code) do
    Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).("aiur: #{message}")
    code
  end
end

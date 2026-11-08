defmodule Aiur.Ownership.GitHubRef do
  @moduledoc """
  Reads, claims, transfers and releases the ticket ownership record at
  `refs/aiur/owners/<ticket>` with compare-and-set only (MPG-101 / KTD-2).

  Every write is a GraphQL `updateRefs` carrying `beforeOid`. A losing write has
  no recognisable error text, so a loss is never inferred from a response: after
  any failed write the ref is re-read once, and only that read decides
  (`:won` if it holds our commit, `:lost` if another record, else `:unknown`).

  Reads use an ordinary GraphQL document no `ReadCache` shape matches, so they
  are never cached. Callers are declared as `:ownership_ref_read` and
  `:ownership_ref_write`.
  """

  alias Aiur.GitHub.Access
  alias Aiur.Ownership.Record

  @zero_oid String.duplicate("0", 40)
  @prefix "refs/aiur/owners/"

  @read_query """
  query($owner:String!,$name:String!,$qualified:String!,$expr:String!){
    repository(owner:$owner,name:$name){
      id
      ref(qualifiedName:$qualified){ target{ oid } }
      object(expression:$expr){ ... on Blob { text } }
    }
  }
  """

  @update_query """
  mutation($input:UpdateRefsInput!){ updateRefs(input:$input){ clientMutationId } }
  """

  @type observed :: %{oid: String.t() | nil, record: Record.t() | nil, repository_id: String.t()}
  @type outcome :: {:won, Record.t()} | {:lost, Record.t()} | {:unknown, term()}

  @doc "Reads the ref head and its record. `oid: nil` means no ref."
  @spec read(String.t(), String.t(), keyword()) :: {:ok, observed()} | {:unknown, term()}
  def read(repo, ticket, opts \\ []) do
    with {:ok, owner, name} <- split_repo(repo),
         :ok <- validate_ticket(ticket),
         {:ok, token} <- Access.require_token(opts),
         ref = @prefix <> ticket,
         vars = %{"owner" => owner, "name" => name, "qualified" => ref, "expr" => ref <> ":owner.json"},
         {:ok, body} <- graphql(@read_query, vars, :ownership_ref_read, token, opts) do
      parse_read(body)
    else
      {:error, reason} -> {:unknown, reason}
      {:unknown, _} = unknown -> unknown
    end
  end

  @doc """
  Claims `ticket` for `claimant` (`gateway_id`, `gateway_label`, `daemon_key`,
  `actor`, `reason`). Absent or released tickets are written at `epoch + 1`; a
  ticket already owned by the same `gateway_id` and `daemon_key` is `:won` with
  no write, one owned by anyone else is `:lost` with no write.
  """
  @spec claim(String.t(), String.t(), map(), keyword()) :: outcome()
  def claim(repo, ticket, claimant, opts \\ []) do
    case read(repo, ticket, opts) do
      {:ok, %{record: nil} = observed} ->
        write(repo, ticket, observed, build(repo, ticket, claimant, "owned", 0, opts), opts)

      {:ok, %{record: %{state: "released", epoch: epoch}} = observed} ->
        write(repo, ticket, observed, build(repo, ticket, claimant, "owned", epoch, opts), opts)

      {:ok, %{record: %{gateway_id: id, daemon_key: key} = record}}
      when id == claimant.gateway_id and key == claimant.daemon_key ->
        {:won, record}

      {:ok, %{record: record}} ->
        {:lost, record}

      {:unknown, _} = unknown ->
        unknown
    end
  end

  @doc "Hands an owned ticket (as `observed` by the caller) to `new_owner`. A stale `observed` is `:lost`."
  @spec transfer(String.t(), String.t(), observed(), map(), keyword()) :: outcome()
  def transfer(repo, ticket, observed, new_owner, opts \\ []) do
    advance(repo, ticket, observed, opts, fn epoch ->
      build(repo, ticket, Map.put(new_owner, :reason, "transfer"), "owned", epoch, opts)
    end)
  end

  @doc "Releases an owned ticket (as `observed` by the caller), keeping the owner fields."
  @spec release(String.t(), String.t(), observed(), keyword()) :: outcome()
  def release(repo, ticket, observed, opts \\ []) do
    advance(repo, ticket, observed, opts, fn epoch ->
      owner = observed.record |> Map.take([:gateway_id, :gateway_label, :daemon_key, :actor]) |> Map.put(:reason, "release")
      build(repo, ticket, owner, "released", epoch, opts)
    end)
  end

  defp advance(repo, ticket, %{record: %Record{state: "owned", epoch: epoch}} = observed, opts, build_fun) do
    write(repo, ticket, observed, build_fun.(epoch), opts)
  end

  defp advance(_repo, _ticket, %{record: %Record{} = record}, _opts, _build_fun), do: {:lost, record}

  defp build(repo, ticket, owner, state, previous_epoch, opts) do
    at = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Record.new(%{
      repo: repo,
      ticket: ticket,
      state: state,
      gateway_id: owner.gateway_id,
      gateway_label: owner.gateway_label,
      daemon_key: owner.daemon_key,
      epoch: previous_epoch + 1,
      previous_epoch: previous_epoch,
      actor: owner.actor,
      reason: owner.reason,
      at: at
    })
  end

  defp write(_repo, _ticket, _observed, {:error, reason}, _opts), do: {:unknown, reason}

  defp write(repo, ticket, observed, {:ok, record}, opts) do
    before = observed.oid

    with {:ok, owner, name} <- split_repo(repo),
         {:ok, token} <- Access.require_token(opts),
         {:ok, blob} <- rest(token, owner, name, "blobs", %{"content" => Record.encode(record), "encoding" => "utf-8"}, opts),
         tree_entry = %{"path" => "owner.json", "mode" => "100644", "type" => "blob", "sha" => blob},
         {:ok, tree} <- rest(token, owner, name, "trees", %{"tree" => [tree_entry]}, opts),
         message = "aiur ownership #{ticket} epoch #{record.epoch}",
         commit = %{"message" => message, "tree" => tree, "parents" => List.wrap(before)},
         {:ok, new} <- rest(token, owner, name, "commits", commit, opts) do
      update = %{"name" => @prefix <> ticket, "beforeOid" => before || @zero_oid, "afterOid" => new}
      vars = %{"input" => %{"repositoryId" => observed.repository_id, "refUpdates" => [update]}}

      case graphql(@update_query, vars, :ownership_ref_write, token, opts) do
        {:ok, _body} -> {:won, record}
        {:error, reason} -> classify_by_reread(repo, ticket, before, new, record, reason, opts)
      end
    else
      # Nothing reached the ref: the blob/tree/commit objects are unreachable garbage.
      {:error, reason} -> {:unknown, reason}
    end
  end

  # No response text is trusted: a held request was never sent, anything else is
  # settled by one uncached read of the ref.
  defp classify_by_reread(_repo, _ticket, _before, _new, _record, {:github, :local_hold, _} = reason, _opts),
    do: {:unknown, reason}

  defp classify_by_reread(repo, ticket, before, new, record, reason, opts) do
    case read(repo, ticket, opts) do
      {:ok, %{oid: ^new}} -> {:won, record}
      {:ok, %{oid: ^before}} -> {:unknown, reason}
      {:ok, %{record: %Record{} = current}} -> {:lost, current}
      {:unknown, error} -> {:unknown, {:reread, error}}
    end
  end

  defp parse_read(%{"data" => %{"repository" => %{"id" => id} = repository}}) when is_binary(id) do
    case repository do
      %{"ref" => nil} ->
        {:ok, %{oid: nil, record: nil, repository_id: id}}

      %{"ref" => %{"target" => %{"oid" => oid}}} when is_binary(oid) ->
        case repository do
          %{"object" => %{"text" => text}} when is_binary(text) -> decode_head(oid, text, id)
          _ -> {:unknown, {:undecodable, :missing_blob}}
        end

      _ ->
        {:unknown, :invalid_response}
    end
  end

  defp parse_read(_body), do: {:unknown, :invalid_response}

  # A corrupt record is never "absent": that would let a second gateway claim over it.
  defp decode_head(oid, text, id) do
    case Record.decode(text) do
      {:ok, record} -> {:ok, %{oid: oid, record: record, repository_id: id}}
      {:error, reason} -> {:unknown, {:undecodable, reason}}
    end
  end

  defp graphql(query, vars, caller, token, opts) do
    case Access.github_graphql_response(request_fun(opts), token, query, vars, caller: caller) do
      {:ok, body, _response} -> {:ok, body}
      {:error, reason, response} -> {:error, graphql_reason(reason, response)}
    end
  end

  defp graphql_reason({:github, :timeout, _}, _response), do: :timeout
  defp graphql_reason(_reason, %{status: 200, body: %{"errors" => [%{"message" => message} | _]}}), do: {:graphql, message}
  defp graphql_reason(_reason, %{status: status, body: %{"message" => message}}) when is_integer(status), do: {:http, status, message}
  defp graphql_reason(reason, _response), do: reason

  defp rest(token, owner, name, path, body, opts) do
    request = %{
      method: :post,
      url: "#{Access.base_url()}/repos/#{owner}/#{name}/git/#{path}",
      token: token,
      caller: "ownership_ref_write",
      body: body
    }

    case request_fun(opts).(request) do
      {:ok, %{status: 201, body: %{"sha" => sha}}} when is_binary(sha) -> {:ok, sha}
      {:ok, %{status: _} = response} -> {:error, Access.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp request_fun(opts), do: Keyword.get(opts, :request_fun, &Access.default_request_fun/1)

  defp split_repo(repo) do
    case String.split(to_string(repo), "/") do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, {:invalid_repo, repo}}
    end
  end

  # The ticket ends up in a ref name, so it is a trust boundary.
  defp validate_ticket(ticket) do
    if is_binary(ticket) and Regex.match?(~r/\A(pr-)?[1-9][0-9]{0,9}\z/, ticket),
      do: :ok,
      else: {:error, {:invalid_ticket, ticket}}
  end
end

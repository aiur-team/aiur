defmodule Aiur.Ownership do
  @moduledoc """
  Dispatch gate for durable ticket ownership (`instance.ownership: github`).

  `ensure_owned/2` runs before every agent start. Tests inject `:ownership_enabled`,
  `:ownership_read_fun`, `:ownership_claim_fun` and `:ownership_self`.
  """

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Ownership.GitHubRef
  alias Aiur.Ownership.Projection
  alias Aiur.Ownership.Record

  @type result :: {:ok, Record.t()} | :disabled | {:declined, :not_owner | :unknown | :ambiguous, term()}

  @spec enabled?() :: boolean()
  def enabled? do
    match?({:ok, %{instance: %{ownership: "github"}}}, Aiur.Config.settings())
  end

  @spec ensure_owned(Aiur.Issue.t(), keyword()) :: result()
  def ensure_owned(issue, opts \\ []) do
    if Keyword.get_lazy(opts, :ownership_enabled, &enabled?/0), do: gate(issue, opts), else: :disabled
  end

  defp gate(issue, opts) do
    read = Keyword.get(opts, :ownership_read_fun, &GitHubRef.read/3)
    claim = Keyword.get(opts, :ownership_claim_fun, &GitHubRef.claim/4)
    ticket = ticket_key(issue)

    with {:ok, self} <- self_identity(opts),
         {:ok, repo} <- repo(issue) do
      observed = read.(repo, ticket, [])

      case Projection.reconcile(ref_read(observed), %{labels: issue.labels, self: self}) do
        {:ambiguous, reason} -> ambiguous(issue, reason, observed, opts)
        {:assignment_request, slugs} -> assignment_request(issue, slugs)
        {:hint_other, slug} -> {:declined, :not_owner, {:label_hint, slug}}
        decision -> proceed(decision, observed, issue, {claim, repo, ticket, self}, opts)
      end
    else
      {:error, why} -> {:declined, :unknown, why}
    end
  end

  defp ref_read({:ok, %{record: %{state: "owned"} = record}}), do: {:owned, record}
  defp ref_read({:ok, _absent_or_released}), do: :unowned
  defp ref_read({:unknown, why}), do: {:unreadable, why}

  # An unreadable ref already holds dispatch; the alert is added only when a gateway label shows
  # someone expects this ticket to be owned.
  defp ambiguous(issue, :ref_unreadable, {:unknown, why}, opts) do
    if Projection.gateway_labels(issue.labels) != [], do: alert(issue, :ref_unreadable, opts)
    {:declined, :unknown, why}
  end

  defp ambiguous(issue, reason, _observed, opts) do
    alert(issue, reason, opts)
    {:declined, :ambiguous, reason}
  end

  defp alert(issue, reason, opts), do: Keyword.get(opts, :ownership_alert_fun, &Projection.alert_ambiguous/2).(issue, reason)

  defp assignment_request(issue, slugs) do
    require Logger
    Logger.info("Ticket ##{issue.identifier} has gateway label(s) #{inspect(slugs)} but no ownership ref or state label; treated as an assignment request, not dispatched")
    {:declined, :not_owner, {:assignment_request, slugs}}
  end

  defp proceed(decision, observed, issue, {claim, repo, ticket, self}, opts) do
    result =
      case observed do
        {:ok, %{record: %{state: "owned"} = record}} -> classify(record, self)
        {:ok, _absent_or_released} -> claim_it(claim, repo, ticket, self)
        {:unknown, why} -> {:declined, :unknown, why}
      end

    # Best effort: a failed label write never undoes a claim; the next poll retries.
    with {:ok, _} <- result, true <- decision == :unlabelled or match?({:project, _}, decision) do
      slug = Projection.slug(self.gateway_label, self.gateway_id)
      Keyword.get(opts, :ownership_label_fun, &Projection.project/2).(issue, slug)
    end

    result
  end

  defp claim_it(claim, repo, ticket, self) do
    case claim.(repo, ticket, Map.merge(self, %{actor: %{kind: "daemon", id: self.daemon_key}, reason: "dispatch"}), []) do
      {:won, record} -> {:ok, record}
      {:lost, record} -> {:declined, :not_owner, record}
      {:unknown, why} -> {:declined, :unknown, why}
    end
  end

  defp classify(%{gateway_id: id, daemon_key: key} = record, %{gateway_id: id, daemon_key: key}), do: {:ok, record}
  defp classify(record, _self), do: {:declined, :not_owner, record}

  @doc false
  @spec ticket_key(Aiur.Issue.t()) :: String.t()
  def ticket_key(%{pr_head_ref: ref, identifier: id}) when is_binary(ref), do: "pr-" <> to_string(id)
  def ticket_key(%{identifier: id}), do: to_string(id)

  defp repo(issue) do
    case Aiur.Issue.tracker_identity(issue) do
      %{status: :joinable, owner: o, repository: r} when is_binary(o) and is_binary(r) -> {:ok, "#{o}/#{r}"}
      _ -> configured_repo()
    end
  end

  defp configured_repo do
    case GitHubConfig.repo() do
      repo when is_binary(repo) -> {:ok, repo}
      _ -> {:error, :no_repository}
    end
  end

  defp self_identity(opts) do
    case Keyword.get(opts, :ownership_self) do
      %{} = self ->
        {:ok, self}

      nil ->
        with %{gateway_id: id, gateway_label: label} when is_binary(id) <- Aiur.Gateway.Identity.current(),
             {:ok, key} <- Aiur.Identity.instance_key() do
          {:ok, %{gateway_id: id, gateway_label: label, daemon_key: key}}
        else
          _ -> {:error, :no_gateway_identity}
        end
    end
  end
end

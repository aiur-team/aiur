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
  alias Aiur.Ownership.WaitingLabel

  @type result :: {:ok, Record.t()} | :disabled | {:declined, :not_owner | :unknown | :ambiguous, term()}

  @spec enabled?() :: boolean()
  def enabled? do
    match?({:ok, %{instance: %{ownership: "github"}}}, Aiur.Config.settings())
  end

  @spec ensure_owned(Aiur.Issue.t(), keyword()) :: result()
  def ensure_owned(issue, opts \\ []) do
    if Keyword.get_lazy(opts, :ownership_enabled, &enabled?/0), do: gate(issue, opts), else: :disabled
  end

  @doc "Durable owner of the ticket from the GitHub ref, or `:unknown` when absent, released or unreadable."
  @spec owner(Aiur.Issue.t(), keyword()) :: {:owner, :self | :other} | :unknown
  def owner(issue, opts \\ []) do
    read = Keyword.get(opts, :ownership_read_fun, &GitHubRef.read/3)

    with {:ok, self} <- self_identity(opts),
         {:ok, repo} <- repo(issue),
         {:ok, %{record: %{state: "owned"} = record}} <- read.(repo, ticket_key(issue), []) do
      if match?({:ok, _}, classify(record, self)), do: {:owner, :self}, else: {:owner, :other}
    else
      _ -> :unknown
    end
  end

  defp gate(issue, opts) do
    read = Keyword.get(opts, :ownership_read_fun, &GitHubRef.read/3)
    claim = Keyword.get(opts, :ownership_claim_fun, &GitHubRef.claim/4)
    ticket = ticket_key(issue)

    with {:ok, self} <- self_identity(opts),
         {:ok, repo} <- repo(issue) do
      observed = read.(repo, ticket, [])
      if Keyword.get(opts, :waiting_pass, true), do: waiting_pass(issue, repo, ticket, observed, self, opts)

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

  @doc """
  Per-poll pass for a ticket this daemon is already running. The ref is not re-read: a running
  ticket was owned at dispatch, so the polled labels are reconciled against our own identity.
  """
  @spec poll_reconcile(Aiur.Issue.t(), keyword()) :: :ok
  def poll_reconcile(issue, opts \\ []) do
    with true <- Keyword.get_lazy(opts, :ownership_enabled, &enabled?/0),
         {:ok, self} <- self_identity(opts) do
      case Projection.reconcile({:owned, self}, %{labels: issue.labels, self: self}) do
        {:project, slug} -> Keyword.get(opts, :ownership_label_fun, &Projection.project/2).(issue, slug)
        {:ambiguous, reason} -> alert(issue, reason, opts)
        _ -> :ok
      end
    end

    :ok
  end

  # Delegator housekeeping on every dispatch look at the ticket; never affects the dispatch result.
  defp waiting_pass(issue, repo, ticket, observed, self, opts) do
    fun = Keyword.get(opts, :waiting_fun, &WaitingLabel.run/5)
    fun.(issue, repo, ticket, ref_read(observed), self.gateway_id)
  end

  defp ref_gateway_id({:owned, record}), do: record.gateway_id
  defp ref_gateway_id(_other), do: nil

  defp ref_read({:ok, %{record: %{state: "owned"} = record}}), do: {:owned, record}
  defp ref_read({:ok, _absent_or_released}), do: :unowned
  defp ref_read({:unknown, why}), do: {:unreadable, why}

  # An unreadable ref already holds dispatch; the alert is added only when a gateway label shows
  # someone expects this ticket to be owned.
  defp ambiguous(issue, :ref_unreadable, {:unknown, why}, opts) do
    if Projection.gateway_labels(issue.labels) != [], do: alert(issue, :ref_unreadable, opts)
    {:declined, :unknown, why}
  end

  defp ambiguous(issue, reason, observed, opts) do
    alert(issue, reason, opts, observed |> ref_read() |> ref_gateway_id())
    {:declined, :ambiguous, reason}
  end

  defp alert(issue, reason, opts, ref_gateway_id \\ nil) do
    case Keyword.get(opts, :ownership_alert_fun) do
      nil -> Projection.alert_ambiguous(issue, reason, ref_gateway_id: ref_gateway_id)
      fun -> fun.(issue, reason)
    end
  end

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

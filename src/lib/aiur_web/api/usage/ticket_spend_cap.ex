defmodule AiurWeb.Api.Usage.TicketSpendCap do
  @moduledoc false

  alias Aiur.{Bounded, Tracker, TrackerIdentity}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Issue
  alias Aiur.Orchestrator.SpendCap.{Record, Store}

  @type error ::
          :invalid_identifier
          | :invalid_amount
          | :unsupported_currency
          | :ticket_not_found
          | :ticket_unresolvable
          | :spend_cap_not_found
          | :spend_cap_exhausted
          | :spend_cap_unavailable
          | :exhaustion_transition_pending

  @spec fetch(term(), keyword()) :: {:ok, map()} | {:error, error()}
  def fetch(identifier, opts \\ []) do
    with {:ok, identifier} <- identifier(identifier) do
      store_get(opts).(identifier)
    end
  end

  @spec put(term(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def put(identifier, params, opts \\ []) do
    with {:ok, identifier} <- identifier(identifier),
         {:ok, amount} <- request_amount(params),
         {:ok, identity} <- resolve_identity(identifier, opts) do
      store_put(opts).(identity, amount)
    end
  end

  @spec delete(term(), keyword()) :: :ok | {:error, error()}
  def delete(identifier, opts \\ []) do
    with {:ok, identifier} <- identifier(identifier) do
      store_delete(opts).(identifier)
    end
  end

  defp identifier(value) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]{0,18}\z/, value), do: {:ok, value}, else: {:error, :invalid_identifier}
  end

  defp identifier(_value), do: {:error, :invalid_identifier}

  defp request_amount(%{"amount" => amount} = params) do
    case Map.get(params, "currency", "USD") do
      "USD" ->
        with {:ok, parsed} <- Record.amount(amount),
             true <- Decimal.compare(parsed, Decimal.new(0)) == :gt do
          {:ok, amount}
        else
          _other -> {:error, :invalid_amount}
        end

      _currency ->
        {:error, :unsupported_currency}
    end
  end

  defp request_amount(_params), do: {:error, :invalid_amount}

  defp resolve_identity(identifier, opts) do
    fetch = Keyword.get(opts, :fetch_issue_states_fun, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, repository} <- repository(opts),
         {:ok, [issue]} <- fetch.([identifier]),
         %TrackerIdentity{} = identity <- Issue.tracker_identity(issue),
         true <- matching_identity?(identity, identifier, repository) do
      {:ok, identity}
    else
      {:ok, []} -> {:error, :ticket_not_found}
      {:ok, _many} -> {:error, :ticket_unresolvable}
      {:error, _reason} -> {:error, :spend_cap_unavailable}
      _other -> {:error, :ticket_unresolvable}
    end
  catch
    :exit, _reason -> {:error, :spend_cap_unavailable}
  end

  defp repository(opts) do
    case Keyword.get(opts, :repository_fun, &GitHubConfig.configured_repo/0).() do
      {:ok, {owner, name}} when is_binary(owner) and is_binary(name) -> {:ok, {owner, name}}
      _other -> {:error, :spend_cap_unavailable}
    end
  end

  defp matching_identity?(identity, identifier, {owner, repository}) do
    TrackerIdentity.joinable?(identity) and identity.identifier == identifier and
      Bounded.same_repository?(identity, %{owner: owner, repository: repository})
  end

  defp store_get(opts), do: Keyword.get(opts, :store_get_fun, &Store.get/1)
  defp store_put(opts), do: Keyword.get(opts, :store_put_fun, &Store.put/2)
  defp store_delete(opts), do: Keyword.get(opts, :store_delete_fun, &Store.delete/1)
end

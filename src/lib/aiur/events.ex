defmodule Aiur.Events do
  @moduledoc """
  Public facade for the event-bus component.

  Delegates to the existing bus without changing publication policy or results.
  See the platform contract `contracts/events-and-replay.md`.
  """

  alias Aiur.Events.{Exchange, IdGenerator, Publisher, Topic}

  @spec publish(String.t(), map(), keyword()) ::
          {:ok, pos_integer(), non_neg_integer()} | :filtered | :deduped | {:error, :decision_requires_durable_publish | :executor_namespace_rejects_github_source}
  defdelegate publish(topic, payload, opts \\ []), to: Publisher

  @spec publish_persisted(String.t(), map(), pos_integer(), keyword()) ::
          {:ok, pos_integer(), non_neg_integer()} | {:error, :executor_namespace_rejects_github_source}
  defdelegate publish_persisted(topic, payload, id, opts \\ []), to: Publisher

  @spec subscribe(String.t()) :: :ok
  defdelegate subscribe(pattern), to: Exchange

  @spec subscribe(String.t(), GenServer.server()) :: :ok
  defdelegate subscribe(pattern, server), to: Exchange

  @spec unsubscribe(String.t()) :: :ok
  defdelegate unsubscribe(pattern), to: Exchange

  @spec unsubscribe(String.t(), GenServer.server()) :: :ok
  defdelegate unsubscribe(pattern, server), to: Exchange

  @spec specificity_score(String.t()) :: integer()
  defdelegate specificity_score(pattern), to: Topic

  @spec bindings_for(pid()) :: [String.t()]
  defdelegate bindings_for(pid), to: Exchange

  @spec matches?(String.t(), String.t()) :: boolean()
  defdelegate matches?(pattern, topic), to: Topic

  @spec next_id() :: pos_integer()
  defdelegate next_id(), to: IdGenerator

  @spec peek() :: non_neg_integer()
  defdelegate peek(), to: IdGenerator

  @spec reserve_durable_id() :: {:ok, pos_integer()} | {:error, :not_durable}
  defdelegate reserve_durable_id(), to: IdGenerator

  @spec set_tracked_fn((String.t() | integer() | nil -> boolean())) :: :ok
  defdelegate set_tracked_fn(fun), to: Publisher

  @doc false
  @spec publisher_available?() :: boolean()
  def publisher_available?, do: Process.whereis(Publisher) != nil

  @doc false
  @spec exchange_server() :: GenServer.server()
  def exchange_server, do: Exchange

  @doc false
  @spec any_subscriber_matches?(String.t()) :: boolean()
  def any_subscriber_matches?(topic) do
    Aiur.Events.SubscriptionStoreRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.any?(fn pid -> Enum.any?(bindings_for(pid), &matches?(&1, topic)) end)
  rescue
    ArgumentError -> false
  end
end

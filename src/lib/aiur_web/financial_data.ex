defmodule AiurWeb.FinancialData do
  @moduledoc """
  Protected query, cache, and PubSub facade for financial dashboard records.

  Authentication is checked before cache access or provider invocation and
  checked again after an uncached provider read. Cache identity is scoped to
  both the authentication configuration and the individual connection.
  """

  alias AiurWeb.FinancialData.Cache
  alias AiurWeb.FinancialDataAccess

  @pubsub Aiur.PubSub
  @topic_prefix "observability:financial:"
  @allowed_sources [:usage_grouping, :provider_meter]
  @authentication_required {:error, :authentication_required}

  @type source :: :usage_grouping | :provider_meter
  @type loader :: (-> term())

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Supervisor.child_spec(%{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}, [])
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts
    |> Keyword.put_new(:name, __MODULE__)
    |> Cache.start_link()
  end

  @doc "Fetches one protected record through the authenticated bounded cache."
  @spec fetch(GenServer.server(), FinancialDataAccess.Context.t() | nil, atom(), term(), non_neg_integer(), loader()) ::
          {:ok, term()}
          | {:error, :authentication_required | :provider_unavailable | :unsupported_financial_source}
  def fetch(server, context, source, key, max_age_ms, loader)
      when is_integer(max_age_ms) and max_age_ms >= 0 and is_function(loader, 0) do
    case FinancialDataAccess.identity(context) do
      {:ok, identity} ->
        with :ok <- validate_source(source) do
          Cache.fetch(server, context, identity, source, key, max_age_ms, loader)
        end

      {:error, :authentication_required} = error ->
        error
    end
  end

  @doc "Fetches an authenticated usage/grouping snapshot."
  @spec fetch_usage_grouping(
          GenServer.server(),
          FinancialDataAccess.Context.t() | nil,
          term(),
          non_neg_integer(),
          loader()
        ) :: {:ok, term()} | {:error, term()}
  def fetch_usage_grouping(server, context, key, max_age_ms, loader),
    do: fetch(server, context, :usage_grouping, key, max_age_ms, loader)

  @doc "Fetches an authenticated provider-meter snapshot."
  @spec fetch_provider_meter(
          GenServer.server(),
          FinancialDataAccess.Context.t() | nil,
          term(),
          non_neg_integer(),
          loader()
        ) :: {:ok, term()} | {:error, term()}
  def fetch_provider_meter(server, context, key, max_age_ms, loader),
    do: fetch(server, context, :provider_meter, key, max_age_ms, loader)

  @doc "Subscribes an authenticated connection to payload-free protected updates."
  @spec subscribe(FinancialDataAccess.Context.t() | nil) :: :ok | {:error, term()}
  def subscribe(context) do
    with {:ok, {configuration_generation, _connection_generation}} <-
           FinancialDataAccess.identity(context),
         true <- is_pid(Process.whereis(@pubsub)) do
      Phoenix.PubSub.subscribe(@pubsub, topic(configuration_generation))
    else
      false -> {:error, :unavailable}
      {:error, :authentication_required} = error -> error
    end
  end

  @doc "Broadcasts a payload-free update only for the current auth generation."
  @spec broadcast_update() :: :ok
  def broadcast_update do
    with {:ok, configuration_generation} <- FinancialDataAccess.current_configuration_generation(),
         pid when is_pid(pid) <- Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(configuration_generation),
        {__MODULE__, :updated, configuration_generation}
      )
    else
      _unavailable_or_locked -> :ok
    end
  end

  @doc "Revalidates a queued protected update before invoking the query facade."
  @spec reload(
          GenServer.server(),
          FinancialDataAccess.Context.t() | nil,
          term(),
          atom(),
          term(),
          non_neg_integer(),
          loader()
        ) :: {:ok, term()} | {:error, term()}
  def reload(server, context, message, source, key, max_age_ms, loader) do
    case FinancialDataAccess.identity(context) do
      {:ok, {configuration_generation, _connection_generation}} ->
        if message == {__MODULE__, :updated, configuration_generation} do
          fetch(server, context, source, key, max_age_ms, loader)
        else
          @authentication_required
        end

      _stale_or_denied ->
        @authentication_required
    end
  end

  defp validate_source(source) when source in @allowed_sources, do: :ok
  defp validate_source(_source), do: {:error, :unsupported_financial_source}

  defp topic(configuration_generation), do: @topic_prefix <> configuration_generation
end

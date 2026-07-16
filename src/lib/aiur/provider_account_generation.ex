defmodule Aiur.ProviderAccountGeneration do
  @moduledoc """
  Owns opaque local account generations for trusted provider auth bindings.

  Bindings, authorities, and topics are local capabilities, never provider
  account identifiers. The owner retains no account payload, credential, or
  provider response data.
  """

  alias Aiur.ProviderAccountGeneration.{Owner, Snapshot}

  @pubsub Aiur.PubSub

  @type provider :: :codex | :claude
  @type backend :: :app_server
  @type binding :: reference()
  @type authority :: reference()
  @type lifecycle_binding :: %{binding: binding(), authority: authority(), topic: String.t()}
  @type snapshot :: %{
          schema_version: pos_integer(),
          provider: provider(),
          backend: backend(),
          generation: String.t() | nil,
          source: atom(),
          freshness: :current | :unknown,
          health: :healthy | :unknown | :unavailable,
          reason: atom() | nil,
          observed_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Owner.start_link(opts)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec lookup(provider(), backend(), binding()) :: snapshot()
  def lookup(provider, backend, binding), do: lookup(__MODULE__, provider, backend, binding)

  @spec lookup(GenServer.server(), provider(), backend(), binding() | lifecycle_binding()) :: snapshot()
  def lookup(server, provider, backend, binding) do
    {binding, _opts} = unwrap_binding(binding, %{})
    safe_call(server, {:lookup, provider, backend, binding}, Snapshot.unavailable(provider, backend))
  end

  @doc false
  @spec issue_binding(GenServer.server(), provider(), backend()) :: {:ok, lifecycle_binding()} | {:error, :owner_unavailable}
  def issue_binding(server, provider, backend), do: safe_call(server, {:issue_binding, provider, backend}, {:error, :owner_unavailable})

  @doc false
  @spec recover_binding(GenServer.server(), provider(), backend(), lifecycle_binding()) :: :ok | {:error, :owner_unavailable}
  def recover_binding(server, provider, backend, %{binding: binding, authority: authority, topic: topic})
      when is_reference(binding) and is_reference(authority) and is_binary(topic) do
    safe_call(server, {:recover_binding, provider, backend, binding, authority, topic}, {:error, :owner_unavailable})
  end

  @spec bind(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def bind(provider, backend, binding, opts \\ []), do: bind(__MODULE__, provider, backend, binding, opts)

  @spec bind(GenServer.server(), provider(), backend(), binding() | lifecycle_binding(), keyword()) :: {:ok, snapshot()}
  def bind(server, provider, backend, binding, opts) when is_list(opts), do: transition(server, :bind, provider, backend, binding, opts)

  @spec replace(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def replace(provider, backend, binding, opts \\ []), do: replace(__MODULE__, provider, backend, binding, opts)

  @spec replace(GenServer.server(), provider(), backend(), binding() | lifecycle_binding(), keyword()) :: {:ok, snapshot()}
  def replace(server, provider, backend, binding, opts) when is_list(opts), do: transition(server, :replace, provider, backend, binding, opts)

  @spec confirm(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def confirm(provider, backend, binding, opts \\ []), do: confirm(__MODULE__, provider, backend, binding, opts)

  @spec confirm(GenServer.server(), provider(), backend(), binding() | lifecycle_binding(), keyword()) :: {:ok, snapshot()}
  def confirm(server, provider, backend, binding, opts) when is_list(opts), do: transition(server, :confirm, provider, backend, binding, opts)

  @spec invalidate(provider(), backend(), binding(), keyword()) :: {:ok, snapshot()}
  def invalidate(provider, backend, binding, opts \\ []), do: invalidate(__MODULE__, provider, backend, binding, opts)

  @spec invalidate(GenServer.server(), provider(), backend(), binding() | lifecycle_binding(), keyword()) :: {:ok, snapshot()}
  def invalidate(server, provider, backend, binding, opts) when is_list(opts), do: transition(server, :invalidate, provider, backend, binding, opts)

  @doc false
  @spec retire(GenServer.server(), provider(), backend(), binding() | lifecycle_binding(), keyword()) :: {:ok, snapshot()}
  def retire(server, provider, backend, binding, opts) when is_list(opts), do: transition(server, :retire, provider, backend, binding, opts)

  @doc "Subscribe the caller to change events for one exact trusted binding."
  @spec subscribe(provider(), backend(), binding()) :: :ok | {:error, term()}
  def subscribe(provider, backend, binding), do: subscribe(__MODULE__, provider, backend, binding)

  @spec subscribe(GenServer.server(), provider(), backend(), binding() | lifecycle_binding()) :: :ok | {:error, term()}
  def subscribe(server, provider, backend, binding) do
    {binding, _opts} = unwrap_binding(binding, %{})

    with {:ok, topic} <-
           safe_call(server, {:subscription_topic, provider, backend, binding}, {:error, :owner_unavailable}) do
      case Process.whereis(@pubsub) do
        pid when is_pid(pid) -> Phoenix.PubSub.subscribe(@pubsub, topic)
        _ -> {:error, :subscription_unavailable}
      end
    end
  end

  defp transition(server, action, provider, backend, binding, opts) do
    {binding, opts} = unwrap_binding(binding, Map.new(opts))
    safe_call(server, {action, provider, backend, binding, Map.new(opts)}, {:ok, Snapshot.unavailable(provider, backend)})
  end

  defp unwrap_binding(%{binding: binding, authority: authority}, opts) when is_reference(binding) and is_reference(authority) do
    {binding, opts |> Map.put_new(:authority, authority) |> unwrap_previous_binding()}
  end

  defp unwrap_binding(binding, opts), do: {binding, unwrap_previous_binding(opts)}

  defp unwrap_previous_binding(%{previous_binding: %{binding: binding, authority: authority}} = opts)
       when is_reference(binding) and is_reference(authority) do
    opts |> Map.put(:previous_binding, binding) |> Map.put_new(:previous_authority, authority)
  end

  defp unwrap_previous_binding(opts), do: opts

  defp safe_call(server, message, fallback) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> fallback
  end
end

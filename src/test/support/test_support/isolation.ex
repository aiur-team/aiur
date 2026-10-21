defmodule Aiur.TestSupport.Isolation do
  @moduledoc "Per-test primitives for state, process, event and log isolation."

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @doc "Temporarily sets application env, restoring the previous value after the test (even on failure)."
  @spec with_app_env!(atom(), atom(), term(), map()) :: :ok
  def with_app_env!(app, key, value, context \\ %{}) do
    ensure_sync!(context)
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)
    ExUnit.Callbacks.on_exit(fn -> restore_app_env(app, key, previous) end)
    :ok
  end

  @doc "Temporarily sets an OS env variable, restoring it after the test (even on failure)."
  @spec with_system_env!(String.t(), String.t() | nil, map()) :: :ok
  def with_system_env!(key, value, context \\ %{}) do
    ensure_sync!(context)
    previous = System.get_env(key)
    if is_nil(value), do: System.delete_env(key), else: System.put_env(key, value)
    ExUnit.Callbacks.on_exit(fn -> restore_system_env(key, previous) end)
    :ok
  end

  @doc "Starts a process under ExUnit supervision so it is stopped with its test."
  @spec start_owned!(Supervisor.child_spec()) :: pid()
  def start_owned!(child_spec), do: start_supervised!(child_spec)

  @doc "Builds a unique, non-global test identifier from ExUnit's owner metadata."
  @spec unique_name(map(), atom()) :: atom()
  def unique_name(%{module: module, test: test}, kind) when is_atom(kind) do
    suffix =
      :crypto.hash(:sha256, :erlang.term_to_binary({module, test, self()}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 20)

    String.to_atom("aiur_test_#{kind}_#{suffix}")
  end

  @doc "Starts an isolated PubSub with an owner-specific name and topic."
  @spec start_pubsub!(map()) :: {atom(), String.t()}
  def start_pubsub!(context) do
    name = unique_name(context, :pubsub)
    topic = unique_name(context, :topic) |> Atom.to_string()
    start_owned!({Phoenix.PubSub, name: name})
    {name, topic}
  end

  @doc "Attaches a telemetry handler and waits for its next event without a timing deadline."
  @spec await_telemetry!([atom()], (-> term())) :: term()
  def await_telemetry!(event, trigger) when is_list(event) and is_function(trigger, 0) do
    ref = make_ref()
    handler = "aiur-test-#{inspect(ref)}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn event_name, measurements, metadata, _ ->
          send(parent, {ref, event_name, measurements, metadata})
        end,
        nil
      )

    try do
      trigger.()

      receive do
        {^ref, event_name, measurements, metadata} -> {event_name, measurements, metadata}
      end
    after
      :telemetry.detach(handler)
    end
  end

  @doc "Captures warning-or-higher logs only while the supplied test-owned processes run."
  @spec capture_owned_log!([pid()], (-> term())) :: {String.t(), term()}
  def capture_owned_log!(pids, fun) when is_list(pids) and is_function(fun, 0) do
    owned = MapSet.new(pids)
    messages = :ets.new(__MODULE__, [:bag, :private])
    handler = "aiur-test-log-#{inspect(make_ref())}"

    :ok =
      :logger.add_handler(handler, Aiur.TestSupport.Isolation.LogHandler, %{
        config: %{table: messages, owned: owned},
        level: :all,
        filters: [],
        filter_default: :log
      })

    try do
      result = fun.()
      captured = :ets.tab2list(messages) |> Enum.map_join("\n", fn {line} -> line end)
      {captured, result}
    after
      :ok = :logger.remove_handler(handler)
      :ets.delete(messages)
    end
  end

  defp ensure_sync!(context) do
    if Map.get(context, :async, false),
      do: raise(ArgumentError, "global environment helpers cannot be used with async: true")
  end

  defp restore_app_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_app_env(app, key, :error), do: Application.delete_env(app, key)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end

defmodule Aiur.TestSupport.Isolation.LogHandler do
  @moduledoc false
  @behaviour :logger_handler
  def adding_handler(config), do: {:ok, config}
  def changing_config(_set_or_update, _old, new), do: {:ok, new}
  def removing_handler(_config), do: :ok
  def filter_config(config), do: config

  def log(%{meta: %{pid: pid}, level: level} = event, %{config: %{table: table, owned: owned}})
      when level in [:warning, :error] do
    if MapSet.member?(owned, pid),
      do: :ets.insert(table, {IO.iodata_to_binary(Logger.Formatter.format_event(event, :infinity))})

    :ok
  end

  def log(_, _), do: :ok
end

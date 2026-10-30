defmodule Aiur.Listener.Scheduler do
  @moduledoc "Resolves conversation delivery from the effective listener mode."

  alias Aiur.AgentQueue
  alias Aiur.Listener.{Spec, SpecStatus}

  @type origin :: :agent_chat | :voice_assistant | :http | :tui | :internal

  @spec routing() :: :unavailable | :listener
  defdelegate routing(), to: Aiur.Listener

  @doc false
  @spec routing(keyword()) :: :unavailable | :listener
  defdelegate routing(opts), to: Aiur.Listener

  @spec spec_status() :: term()
  def spec_status, do: SpecStatus.read()

  @spec resolve(origin(), map() | nil, map(), atom() | nil) :: {:ok, keyword()} | {:error, atom()}
  def resolve(origin, view, capabilities, fallback), do: resolve(origin, view, capabilities, fallback, [])

  @doc false
  @spec resolve(origin(), map() | nil, map(), atom() | nil, keyword()) :: {:ok, keyword()} | {:error, atom()}
  def resolve(_origin, view, _capabilities, _fallback, opts) do
    case routing(opts) do
      :unavailable -> {:error, :listener_mode_unavailable}
      :listener -> listener(view)
    end
  end

  @doc "Decide an external hook boundary using the pinned table; prompt is the start of a user turn."
  @spec hook_delivers?(String.t(), atom(), atom()) :: boolean()
  def hook_delivers?(harness, mode, boundary) do
    case Spec.scheduler_rows() do
      rows when is_list(rows) ->
        Enum.any?(rows, fn row ->
          row["harness"] == harness and row["mode"] == to_string(mode) and row["event"] == to_string(boundary) and
            row["busy"] == false and row["continuation"] == false and row["delivers"] == true
        end)

      _ ->
        false
    end
  end

  @spec async_usable?(map()) :: boolean()
  def async_usable?(%{support: %{async: %{status: status}}}), do: status in [:proven, :experimental]
  def async_usable?(_view), do: false

  @spec restamp_fun(map()) :: (map() -> map())
  def restamp_fun(view) do
    usable? = async_usable?(view)

    fn
      %{consume_at: :pull} = delivery when usable? ->
        delivery

      delivery ->
        case listener(view) do
          {:ok, opts} -> Map.merge(Map.delete(delivery, :steer_requested), AgentQueue.operator_message("", "", opts).delivery)
          {:error, _} -> delivery
        end
    end
  end

  defp listener(%{effective: :sync}), do: {:ok, [delivery_policy: :checkpoint, listener_mode: :sync]}
  defp listener(%{effective: :async}), do: {:ok, [listener_mode: :async]}

  defp listener(%{effective: :steer, support: %{steer: %{carrier: :emulated_interrupt}}}),
    do: {:ok, [delivery_policy: :interrupt, fallback: :queue_next, listener_mode: :steer, steer_carrier: :emulated_interrupt]}

  defp listener(%{effective: :steer, support: %{steer: %{carrier: :native}}}),
    do: {:ok, [listener_mode: :steer, steer_carrier: :native]}

  defp listener(_view), do: {:error, :listener_mode_unavailable}
end

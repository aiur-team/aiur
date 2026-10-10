defmodule Aiur.BuildQueue.Settings do
  @moduledoc "Resolves build queue settings from validated workflow configuration."

  alias Aiur.Config.Schema

  @spec start_trigger(Schema.t()) :: Aiur.StartTrigger.trigger()
  def start_trigger(%Schema{} = settings) do
    {:ok, trigger} = Aiur.StartTrigger.parse(settings.build_queue.start_trigger)
    trigger
  end

  @spec effective_trigger(Aiur.BuildQueue.Model.Queue.t(), Schema.t()) :: Aiur.StartTrigger.trigger()
  def effective_trigger(queue, settings), do: queue.start_trigger || start_trigger(settings)

  @doc "Returns the configured observation age, or twice the base poll interval, in milliseconds."
  @spec observation_max_age_ms(Schema.t()) :: pos_integer()
  def observation_max_age_ms(%Schema{} = settings) do
    (settings.build_queue.observation_max_age_seconds || 2 * settings.polling.interval_seconds) * 1000
  end
end

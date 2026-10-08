defmodule Aiur.BuildQueue.Settings do
  @moduledoc "Resolves build queue settings from validated workflow configuration."

  alias Aiur.Config.Schema

  @doc "Returns the configured observation age, or twice the base poll interval, in milliseconds."
  @spec observation_max_age_ms(Schema.t()) :: pos_integer()
  def observation_max_age_ms(%Schema{} = settings) do
    (settings.build_queue.observation_max_age_seconds || 2 * settings.polling.interval_seconds) * 1000
  end
end

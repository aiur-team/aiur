defmodule Aiur.Commands.OptionMedia do
  @moduledoc """
  Refuses a Command whose options lack media when the project sets
  `decisions.require_option_media`.

  A person choosing between visual options (open-games #469, #512: five
  mode-screen looks offered as text only) cannot judge them without seeing
  each one, and a prompt rule alone did not stop workers raising them.
  """

  alias Aiur.Commands.Requester
  alias Aiur.Config

  @checked_origins [:emit_event, :executor_cli]

  @spec validate(Aiur.Decision.t(), keyword()) :: :ok | {:error, term()}
  def validate(decision, opts) do
    origin = Keyword.get(opts, :origin, Requester.origin(decision))

    with true <- origin in @checked_origins,
         true <- Config.decisions_require_option_media?(),
         [_ | _] = missing <- for(%{media: media, id: id} <- decision.options, media in [nil, []], do: id) do
      {:error, {:decision_invalid, {:option_media_missing, missing}}}
    else
      _checked_or_exempt -> :ok
    end
  end
end

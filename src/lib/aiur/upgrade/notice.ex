defmodule Aiur.Upgrade.Notice do
  @moduledoc false
  # A pending upgrade notice: what is installed, what is available on the
  # user's channel, the exact command to run, and the rendered text. `available`
  # is nil for a "channel no longer publishes" notice (with `channel_gone` set),
  # in which case `command` is also nil — there is no upgrade to offer.
  defstruct installed: nil,
            available: nil,
            channel: nil,
            command: nil,
            text: nil,
            channel_gone: false

  @type t :: %__MODULE__{
          installed: String.t(),
          available: String.t() | nil,
          channel: :latest | :next | :nightly | nil,
          command: String.t() | nil,
          text: String.t(),
          channel_gone: boolean()
        }
end

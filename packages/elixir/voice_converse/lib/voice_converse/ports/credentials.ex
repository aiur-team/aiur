defmodule VoiceConverse.Ports.Credentials do
  @moduledoc """
  Required port: provider secrets, fetched at the moment of use. The secret must never be kept
  in process state or logs.
  """

  @callback fetch(provider :: atom(), purpose :: :connect | :provision | :delete) ::
              {:ok, String.t()} | {:error, :missing}
end

defmodule VoiceConverse.Ports.Credentials do
  @moduledoc """
  Required port: provider secrets, fetched at the moment of use. The secret must never be kept
  in process state or logs. A `:probe` returns only `:present`; every other purpose returns the
  secret binary when it exists.
  """

  @type secret_purpose :: :connect | :delete | :provision | :render
  @type purpose :: :probe | secret_purpose()

  @callback fetch(provider :: atom(), :probe) :: {:ok, :present} | {:error, :missing}
  @callback fetch(provider :: atom(), secret_purpose()) :: {:ok, String.t()} | {:error, :missing}
end

defmodule AiurPushRelay.LogFilter do
  @moduledoc "Drops sensitive metadata at the standalone service logger boundary."

  def install do
    :logger.add_primary_filter(:relay_secrets, {&__MODULE__.filter/2, nil})
  end

  def filter(%{meta: metadata} = event, _) do
    %{event | meta: Map.drop(metadata, [:sealed, :push_token, :send_secret])}
  end
end

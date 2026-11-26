defmodule AiurPushRelay.Provider.Fake do
  @moduledoc "Test provider controlled by the configured :fake_owner process, independent of stored rows."
  @behaviour AiurPushRelay.Provider

  @impl true
  def deliver(row, envelope) do
    owner = Application.fetch_env!(:aiur_push_relay, :fake_owner)
    send(owner, {:delivery, self(), row, envelope})

    receive do
      {:result, :raise} -> raise "fake provider failure: #{row.push_token} #{envelope["sealed"]}"
      {:result, result} -> result
    after
      2000 -> :ok
    end
  end
end

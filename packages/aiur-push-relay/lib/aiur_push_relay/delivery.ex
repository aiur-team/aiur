defmodule AiurPushRelay.Delivery do
  @moduledoc "Contains provider failures so OTP crash reports cannot expose envelope or token arguments."
  require Logger

  def run(provider, row, envelope) do
    case provider.deliver(row, envelope) do
      :ok -> :delivered
      {:gone, _} -> :gone
      {:retry, _} -> :retry
      {:error, _} -> :error
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def log(handle, envelope, status) do
    Logger.info("relay_delivery",
      handle: handle,
      status: status,
      size: byte_size(envelope["sealed"])
    )
  end
end

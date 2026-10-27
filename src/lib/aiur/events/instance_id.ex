defmodule Aiur.Events.InstanceId do
  @moduledoc """
  Reads the instance identity that the external event feed stamps into envelopes.

  The exporter reads this once per boot. It must not start when identity is
  unavailable, and it starts a new epoch when the value differs from the
  persisted export metadata on a later boot.
  """

  # aiur:event-bus-boundary-member

  @type reason :: :identity_unavailable

  @spec current() :: {:ok, String.t()} | {:error, reason()}
  def current do
    case provider().instance_id() do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :identity_unavailable}
    end
  rescue
    _ -> {:error, :identity_unavailable}
  catch
    _kind, _reason -> {:error, :identity_unavailable}
  end

  defp provider, do: Application.fetch_env!(:aiur, __MODULE__)
end

defmodule Aiur.Gateway.Identity do
  @moduledoc """
  The gateway identity: the durable machine id shared by every daemon on this machine.

  Distinct from `instance_id`, which names one daemon. An unreadable identity collapses to
  a cause-neutral `"unavailable"`; an id is never invented.
  """

  @type t :: %{gateway_id: String.t() | nil, gateway_label: String.t() | nil, gateway_identity: String.t()}

  @spec current() :: t()
  def current do
    case Aiur.Identity.machine() do
      {:ok, %{machine_id: id, label: label}} -> %{gateway_id: id, gateway_label: label, gateway_identity: "available"}
      {:degraded, _reason} -> %{gateway_id: nil, gateway_label: nil, gateway_identity: "unavailable"}
    end
  end
end

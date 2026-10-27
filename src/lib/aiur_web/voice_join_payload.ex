defmodule AiurWeb.VoiceJoinPayload do
  @moduledoc """
  Strict parser for the `voice:dictate` join payload (voice-session contract
  §3.2, target shapes §5.1).

  An empty payload is today's browser: a legacy join with no target. A payload
  naming `"v" => 1` must match the v1 shape exactly; an unknown key, a missing
  required key, a wrong type or an oversized string refuses the join, so a
  client bug cannot slip an unvalidated field past the daemon.
  """

  # Every contract surface parses; `VoiceTargets` refuses `command_revision`
  # and `conversation_panel` until the tickets that own them land.
  @surfaces ~w(agent_composer executor_composer command_response command_revision conversation_panel)
  @client_kinds ~w(dashboard phone watch streamdeck)
  @session_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @max_ref_bytes 256

  @top_keys %{required: ~w(v mode surface target client_session_id), optional: ~w(client)}
  @target_keys %{
    "worker" => %{required: ~w(kind ticket), optional: ~w(instance_id session_id)},
    "executor" => %{required: ~w(kind), optional: ~w(instance_id)},
    "command" => %{required: ~w(kind decision_id), optional: ~w(instance_id expected_version)}
  }

  @type target ::
          %{kind: :worker, ticket: String.t(), instance_id: String.t() | nil}
          | %{kind: :executor, instance_id: String.t() | nil}
          | %{kind: :command, decision_id: String.t(), expected_version: pos_integer() | nil, instance_id: String.t() | nil}

  @type t :: %{surface: String.t(), target: target(), client_session_id: String.t()}

  @spec parse(term()) :: :legacy | {:ok, t()} | {:error, :invalid_payload}
  def parse(payload) when payload == %{}, do: :legacy

  def parse(%{"v" => 1, "mode" => "dictate", "surface" => surface, "target" => target} = payload)
      when surface in @surfaces do
    with true <- keys_allowed?(payload, @top_keys),
         true <- Regex.match?(@session_id, to_string_or_empty(payload["client_session_id"])),
         true <- client_valid?(Map.get(payload, "client")),
         {:ok, target} <- parse_target(target) do
      {:ok, %{surface: surface, target: target, client_session_id: payload["client_session_id"]}}
    else
      _invalid -> {:error, :invalid_payload}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_target(%{"kind" => kind} = target) when is_map_key(@target_keys, kind) do
    with true <- keys_allowed?(target, Map.fetch!(@target_keys, kind)),
         true <- Enum.all?(Map.delete(target, "expected_version"), fn {_key, value} -> ref?(value) end),
         true <- version?(Map.get(target, "expected_version")) do
      {:ok, target_fields(kind, target)}
    end
  end

  defp parse_target(_target), do: :error

  defp target_fields("worker", target), do: %{kind: :worker, ticket: target["ticket"], instance_id: target["instance_id"]}
  defp target_fields("executor", target), do: %{kind: :executor, instance_id: target["instance_id"]}

  defp target_fields("command", target),
    do: %{kind: :command, decision_id: target["decision_id"], expected_version: target["expected_version"], instance_id: target["instance_id"]}

  defp keys_allowed?(map, %{required: required, optional: optional}) do
    keys = Map.keys(map)
    Enum.all?(required, &Map.has_key?(map, &1)) and Enum.all?(keys, &(&1 in required or &1 in optional))
  end

  defp client_valid?(nil), do: true

  defp client_valid?(%{"kind" => kind} = client) when kind in @client_kinds do
    keys_allowed?(client, %{required: ~w(kind), optional: ~w(version)}) and
      (not Map.has_key?(client, "version") or ref?(client["version"]))
  end

  defp client_valid?(_client), do: false

  defp ref?(value), do: is_binary(value) and value != "" and byte_size(value) <= @max_ref_bytes

  defp version?(nil), do: true
  defp version?(version), do: is_integer(version) and version > 0

  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(_value), do: ""
end

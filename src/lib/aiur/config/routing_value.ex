defmodule Aiur.Config.RoutingValue do
  @moduledoc "Pure grammar of a routing value backend[:model[:effort]][+remote] — parsing only, no validation."

  @doc """
  Splits a routing value into its backend and optional model. A routing
  value is `"<backend>"`, `"<backend>:<model>"` (e.g. `"claude:sonnet"`), or
  `"<backend>:<model>:<effort>"` (e.g. `"codex:gpt-5.5:high"`), optionally
  with a trailing `+remote` flag (`"claude:haiku+remote"`) that is stripped
  here and surfaced separately by `routing_remote_flag?/1`. The optional
  trailing effort segment is dropped here and surfaced by `routing_effort/1`;
  an effort-only value omits the model (`"codex::high"`).
  """
  @spec split_routing_value(String.t()) :: {String.t(), String.t() | nil}
  def split_routing_value(value) when is_binary(value) do
    case value |> strip_remote_flag() |> String.split(":", parts: 3) do
      [backend, model | _] when model != "" -> {backend, model}
      [backend | _] -> {backend, nil}
    end
  end

  @doc """
  The optional per-complexity effort carried by a routing value's third
  `:`-separated segment (`"<backend>:<model>:<effort>"` or the model-less
  `"<backend>::<effort>"`), or `nil` when no effort is pinned. The valid
  set is backend-aware (see `Aiur.CodingAgent.efforts/1`) and enforced by
  `Aiur.Config.Schema.AgentValidation.validate_agent_routing/2`.
  """
  @spec routing_effort(String.t()) :: String.t() | nil
  def routing_effort(value) when is_binary(value) do
    case value |> strip_remote_flag() |> String.split(":", parts: 3) do
      [_backend, _model, effort] when effort != "" -> effort
      _ -> nil
    end
  end

  @doc "Whether a routing value carries the optional trailing `+remote` flag."
  @spec routing_remote_flag?(String.t()) :: boolean()
  def routing_remote_flag?(value) when is_binary(value), do: String.ends_with?(value, "+remote")

  @doc "The backend portion of a routing value, or nil for non-binary input."
  @spec routing_backend(String.t() | term()) :: String.t() | nil
  def routing_backend(value) when is_binary(value), do: value |> split_routing_value() |> elem(0)
  def routing_backend(_value), do: nil

  @spec strip_remote_flag(String.t()) :: String.t()
  def strip_remote_flag(value), do: String.replace_suffix(value, "+remote", "")
end

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

  @doc """
  The model portion of a routing value, or nil when the value names only a
  backend (`"claude"`, or the effort-only `"codex::high"`). Non-binary input
  yields nil so callers can treat a malformed entry as "no model pinned".
  """
  @spec routing_model(String.t() | term()) :: String.t() | nil
  def routing_model(value) when is_binary(value), do: value |> split_routing_value() |> elem(1)
  def routing_model(_value), do: nil

  @doc """
  The model **set** a routing value's model segment carries, as a list of
  model strings — `"openrouter:{vendor/a, vendor/b}"` yields
  `{:ok, ["vendor/a", "vendor/b"]}`.

  A set is how a route hands model choice to an aggregator instead of pinning
  one model. Anything that is not brace-shaped is a single model, and a
  brace-shaped segment that does not hold a non-empty comma-separated list is
  `:error`, so callers can tell "not a set" from "malformed set" with
  `model_set?/1`.
  """
  @spec model_set(String.t() | term()) :: {:ok, [String.t()]} | :error
  def model_set(value) when is_binary(value) do
    trimmed = String.trim(value)

    with "{" <> rest <- trimmed,
         true <- String.ends_with?(rest, "}"),
         inner = binary_part(rest, 0, byte_size(rest) - 1),
         false <- String.contains?(inner, ["{", "}"]),
         models = inner |> String.split(",") |> Enum.map(&String.trim/1),
         true <- models != [] and Enum.all?(models, &(&1 != "")) do
      {:ok, models}
    else
      _not_a_set -> :error
    end
  end

  def model_set(_value), do: :error

  @doc "Whether a model segment is written in set form, valid or not."
  @spec model_set?(String.t() | term()) :: boolean()
  def model_set?(value) when is_binary(value), do: String.starts_with?(String.trim(value), "{")
  def model_set?(_value), do: false

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

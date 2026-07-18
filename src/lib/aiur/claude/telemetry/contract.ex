defmodule Aiur.Claude.Telemetry.Contract do
  @moduledoc false

  @source "claude_code.api_request"
  @source_version "claude-code-2.1.210"
  @emitter_version "2.1.210"
  @service_name "claude-code"
  @max_decimal_bytes 128
  @query_sources ~w(repl_main_thread compact subagent)
  @built_in_subagent_sources ~w(Explore Plan)
  @max_subagent_source_bytes 96
  @subagent_source_pattern ~r/\A[a-z]+(?:-[a-z]+)*(?::[a-z]+(?:-[a-z]+)*){0,2}\z/
  @efforts ~w(low medium high xhigh max)
  @session_id_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  @request_id_pattern ~r/\Areq_[A-Za-z0-9]{24}\z/
  @model_pattern ~r/\Aclaude-(?:(?:opus|sonnet|haiku)-[0-9]+(?:-[0-9]+)*(?:-[0-9]{8})?|[0-9]+(?:-[0-9]+)*-(?:opus|sonnet|haiku)(?:-[0-9]{8})?)\z/

  @spec source() :: String.t()
  def source, do: @source

  @spec source_version() :: String.t()
  def source_version, do: @source_version

  @spec emitter_version() :: String.t()
  def emitter_version, do: @emitter_version

  @spec service_name() :: String.t()
  def service_name, do: @service_name

  @spec valid_query_source?(term()) :: boolean()
  def valid_query_source?(value), do: value in @query_sources

  @spec normalize_query_source(term()) :: {:ok, String.t()} | :error
  def normalize_query_source(value) when value in ~w(repl_main_thread compact), do: {:ok, value}

  def normalize_query_source(value) when is_binary(value) do
    if value in @built_in_subagent_sources or
         (byte_size(value) <= @max_subagent_source_bytes and Regex.match?(@subagent_source_pattern, value)) do
      {:ok, "subagent"}
    else
      :error
    end
  end

  def normalize_query_source(_value), do: :error

  @spec valid_effort?(term()) :: boolean()
  def valid_effort?(value), do: value in @efforts

  @spec valid_session_id?(term()) :: boolean()
  def valid_session_id?(value) when is_binary(value), do: Regex.match?(@session_id_pattern, value)
  def valid_session_id?(_value), do: false

  @spec valid_request_id?(term()) :: boolean()
  def valid_request_id?(value) when is_binary(value), do: Regex.match?(@request_id_pattern, value)
  def valid_request_id?(_value), do: false

  @spec valid_model?(term()) :: boolean()
  def valid_model?(value) when is_binary(value), do: byte_size(value) <= 96 and Regex.match?(@model_pattern, value)
  def valid_model?(_value), do: false

  @spec exact_cost(term()) :: {:ok, Decimal.t()} | :error
  def exact_cost(%Decimal{} = value) do
    if bounded_decimal?(value) and not Decimal.negative?(value), do: {:ok, value}, else: :error
  end

  def exact_cost(value) when is_integer(value) and value >= 0 do
    decimal = Decimal.new(value)
    if bounded_decimal?(decimal), do: {:ok, decimal}, else: :error
  end

  def exact_cost(_value), do: :error

  @spec bounded_decimal?(term()) :: boolean()
  def bounded_decimal?(%Decimal{coef: coefficient, exp: exponent} = value)
      when is_integer(coefficient) and is_integer(exponent) and abs(exponent) <= @max_decimal_bytes do
    not Decimal.nan?(value) and not Decimal.inf?(value) and
      byte_size(Integer.to_string(coefficient)) <= @max_decimal_bytes and
      byte_size(Decimal.to_string(value, :normal)) <= @max_decimal_bytes
  end

  def bounded_decimal?(_value), do: false
end

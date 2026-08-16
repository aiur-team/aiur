defmodule Aiur.ModelDiscovery.Source do
  @moduledoc """
  Behaviour every provider catalogue adapter implements.

  There is one discovery mechanism (`Aiur.ModelDiscovery`) and one adapter per
  wire shape, selected from registry data — the `openai_compat.models_endpoint`
  key on a backend's `Aiur.CodingAgent.backends/0` entry names the module. A
  backend without that key simply is not discoverable, which is how a provider
  with no catalogue endpoint opts out without any code in the orchestrator
  knowing its name.

  `request/2` turns the registry's `openai_compat` map plus an already-resolved
  API key into the HTTP request to make. `parse/1` turns a decoded response body
  into normalized `t:model/0` maps. Neither performs IO, so both are testable
  against fixtures with no network.
  """

  @typedoc """
  One discovered model. Only `:id` is guaranteed: most provider catalogues
  return identifiers and nothing else. `:pricing` is in major USD units per
  one million tokens, matching `Aiur.Usage.PriceTable`'s `token_unit`.
  """
  @type model :: %{
          required(:id) => String.t(),
          optional(:display_name) => String.t(),
          optional(:context_length) => pos_integer(),
          optional(:pricing) => %{atom() => Decimal.t()}
        }

  @type request :: %{url: String.t(), headers: [{String.t(), String.t()}]}

  @doc """
  The catalogue request for this provider, or `{:error, reason}` when it cannot
  be built — an absent API key for a provider that requires one is the normal
  case, not a bug.
  """
  @callback request(instance :: map(), api_key :: String.t() | nil) :: {:ok, request()} | {:error, term()}

  @doc "Normalized models from a decoded response body."
  @callback parse(body :: term()) :: {:ok, [model()]} | {:error, term()}

  @doc """
  The catalogue URL for a registry instance: its `base_url` with `path`
  appended, tolerating a base that already carries a trailing slash.
  """
  @spec models_url(map(), String.t()) :: String.t()
  def models_url(instance, path \\ "/models") do
    instance |> Map.get(:base_url, "") |> String.trim_trailing("/") |> Kernel.<>(path)
  end

  @doc """
  Normalizes an `{id, extras}` pair into a `t:model/0`, dropping keys whose
  value the provider omitted. Adapters use this so an absent field is absent
  rather than `nil`, which keeps the JSON cache free of null noise.
  """
  @spec model(term(), map()) :: [model()]
  def model(id, extras \\ %{})

  def model(id, extras) when is_binary(id) do
    [extras |> Map.reject(fn {_key, value} -> is_nil(value) end) |> Map.put(:id, id)]
  end

  def model(_id, _extras), do: []

  @doc "A positive integer context window, or `nil` for anything else."
  @spec context_length(term()) :: pos_integer() | nil
  def context_length(value) when is_integer(value) and value > 0, do: value
  def context_length(_value), do: nil

  @doc "A non-empty display name, or `nil`."
  @spec display_name(term()) :: String.t() | nil
  def display_name(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def display_name(_value), do: nil
end

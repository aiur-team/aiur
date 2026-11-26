defmodule Aiur.CodingAgent.ConfigCatalog do
  @moduledoc false
  @behaviour Aiur.Config.BackendCatalog

  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.Models

  @impl true
  defdelegate known_backends(), to: CodingAgent

  @impl true
  defdelegate default_backend(), to: CodingAgent

  @impl true
  defdelegate default_config_backend(), to: CodingAgent

  @impl true
  defdelegate default_rate_limit_fallback(), to: CodingAgent

  @impl true
  defdelegate rate_limit_fallback_targets(), to: CodingAgent

  @impl true
  defdelegate configurable_backends(), to: CodingAgent

  @impl true
  defdelegate dispatchable_backends(configs), to: CodingAgent

  @impl true
  defdelegate models(backend), to: CodingAgent

  @impl true
  defdelegate complexity_level(issue), to: CodingAgent

  @impl true
  defdelegate remote_control?(backend), to: CodingAgent

  @impl true
  defdelegate model_required?(backend), to: CodingAgent

  @impl true
  defdelegate efforts(backend), to: CodingAgent

  @impl true
  def config_validator(backend), do: get_in(CodingAgent.backends(), [backend, :config_validator])

  @impl true
  def ambiguous_model_alias?(backend, model) do
    is_binary(model) and CodingAgent.model_aliases(backend) != [] and
      Models.ambiguous_alias?(CodingAgent.models(backend), model)
  end
end

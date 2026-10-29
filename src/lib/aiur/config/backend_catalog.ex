defmodule Aiur.Config.BackendCatalog do
  @moduledoc "Backend questions supplied by the application composition, without a config-to-harness dependency."

  @type unavailable :: {:error, :backend_catalog_unavailable}
  @callback known_backends() :: [String.t()]
  @callback default_backend() :: String.t()
  @callback default_config_backend() :: String.t()
  @callback default_rate_limit_fallback() :: String.t()
  @callback rate_limit_fallback_targets() :: [String.t()]
  @callback configurable_backends() :: [String.t()]
  @callback dispatchable_backends(map()) :: [String.t()]
  @callback config_validator(String.t()) :: (map() -> :ok | {:error, term()}) | nil
  @callback models(String.t()) :: [String.t()]
  @callback ambiguous_model_alias?(String.t(), String.t() | nil) :: boolean()
  @callback complexity_level(map()) :: pos_integer() | nil
  @callback remote_control?(String.t()) :: boolean()
  @callback model_required?(String.t()) :: boolean()
  @callback efforts(String.t()) :: [String.t()]

  @spec impl() :: {:ok, module()} | unavailable()
  def impl do
    case Application.fetch_env(:aiur, :backend_catalog) do
      {:ok, module} when is_atom(module) and not is_nil(module) -> {:ok, module}
      _ -> {:error, :backend_catalog_unavailable}
    end
  end

  @spec known_backends() :: [String.t()] | unavailable()
  def known_backends do
    with {:ok, module} <- impl(), do: module.known_backends()
  end

  @spec default_backend() :: String.t() | unavailable()
  def default_backend do
    with {:ok, module} <- impl(), do: module.default_backend()
  end

  @spec default_config_backend() :: String.t() | unavailable()
  def default_config_backend do
    with {:ok, module} <- impl(), do: module.default_config_backend()
  end

  @spec default_rate_limit_fallback() :: String.t() | unavailable()
  def default_rate_limit_fallback do
    with {:ok, module} <- impl(), do: module.default_rate_limit_fallback()
  end

  @spec rate_limit_fallback_targets() :: [String.t()] | unavailable()
  def rate_limit_fallback_targets do
    with {:ok, module} <- impl(), do: module.rate_limit_fallback_targets()
  end

  @spec configurable_backends() :: [String.t()] | unavailable()
  def configurable_backends do
    with {:ok, module} <- impl(), do: module.configurable_backends()
  end

  @spec dispatchable_backends(map()) :: [String.t()] | unavailable()
  def dispatchable_backends(configs) do
    with {:ok, module} <- impl(), do: module.dispatchable_backends(configs)
  end

  @spec config_validator(String.t()) :: (map() -> :ok | {:error, term()}) | nil | unavailable()
  def config_validator(backend) do
    with {:ok, module} <- impl(), do: module.config_validator(backend)
  end

  @spec models(String.t()) :: [String.t()] | unavailable()
  def models(backend) do
    with {:ok, module} <- impl(), do: module.models(backend)
  end

  @spec ambiguous_model_alias?(String.t(), String.t() | nil) :: boolean() | unavailable()
  def ambiguous_model_alias?(backend, model) do
    with {:ok, module} <- impl(), do: module.ambiguous_model_alias?(backend, model)
  end

  @spec complexity_level(map()) :: pos_integer() | nil | unavailable()
  def complexity_level(issue) do
    with {:ok, module} <- impl(), do: module.complexity_level(issue)
  end

  @spec remote_control?(String.t()) :: boolean() | unavailable()
  def remote_control?(backend) do
    with {:ok, module} <- impl(), do: module.remote_control?(backend)
  end

  @spec model_required?(String.t()) :: boolean() | unavailable()
  def model_required?(backend) do
    with {:ok, module} <- impl(), do: module.model_required?(backend)
  end

  @spec efforts(String.t()) :: [String.t()] | unavailable()
  def efforts(backend) do
    with {:ok, module} <- impl(), do: module.efforts(backend)
  end
end

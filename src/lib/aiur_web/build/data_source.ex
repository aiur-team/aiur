defmodule AiurWeb.Build.DataSource do
  @moduledoc "Read seam for the build home page; the default source is not wired yet."

  @callback subscribe(keyword()) :: :ok | {:error, term()}
  @callback snapshot(keyword()) :: {:ok, map()} | {:error, term()}

  @spec source() :: module() | {module(), keyword()}
  def source, do: Application.get_env(:aiur, :build_data_source, __MODULE__)

  @spec call(module() | {module(), keyword()}, atom(), [term()]) :: term()
  def call({module, opts}, function, args) when is_atom(module) and is_list(opts),
    do: apply(module, function, args ++ [opts])

  def call(module, function, args) when is_atom(module), do: apply(module, function, args ++ [[]])

  @spec subscribe(keyword()) :: :ok
  def subscribe(_opts), do: :ok

  @spec snapshot(keyword()) :: {:error, :not_wired}
  def snapshot(_opts), do: {:error, :not_wired}
end

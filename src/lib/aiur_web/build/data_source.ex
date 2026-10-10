defmodule AiurWeb.Build.DataSource do
  @moduledoc "Read seam for the build home page; the default source is not wired yet."

  @callback subscribe(keyword()) :: :ok | {:error, term()}
  @callback snapshot(keyword()) :: {:ok, map()} | {:error, term()}
  @callback earlier(integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @spec source() :: module() | {module(), keyword()}
  def source, do: Application.get_env(:aiur, :build_data_source, __MODULE__)

  @spec call(module() | {module(), keyword()}, atom(), [term()]) :: term()
  def call({module, opts}, function, args) when is_atom(module) and is_list(opts),
    do: apply(module, function, merge_opts(args, opts))

  def call(module, function, args) when is_atom(module), do: apply(module, function, merge_opts(args, []))

  @spec subscribe(keyword()) :: :ok
  def subscribe(_opts), do: :ok

  @spec snapshot(keyword()) :: {:error, :not_wired}
  def snapshot(_opts), do: {:error, :not_wired}
  @spec earlier(integer(), String.t(), keyword()) :: {:error, :not_wired}
  def earlier(_before, _zone, _opts), do: {:error, :not_wired}

  defp merge_opts([], opts), do: [opts]

  defp merge_opts(args, opts) do
    if Keyword.keyword?(List.last(args)), do: List.replace_at(args, -1, Keyword.merge(opts, List.last(args))), else: args ++ [opts]
  end
end

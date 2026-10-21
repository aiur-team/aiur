defmodule AiurWeb.Build.DataSource do
  @moduledoc "Read seam for the build home page; real index by default, fixtures selectable."

  @callback subscribe(keyword()) :: :ok | {:error, term()}
  @callback snapshot(keyword()) :: {:ok, map()} | {:error, term()}
  @callback earlier(integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback ticket(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback daemon(keyword()) :: map() | nil
  @optional_callbacks daemon: 1

  @spec source() :: module() | {module(), keyword()}
  def source, do: Application.get_env(:aiur, :build_data_source, AiurWeb.Build.IndexSource)

  @spec call(module() | {module(), keyword()}, atom(), [term()]) :: term()
  def call({module, opts}, function, args) when is_atom(module) and is_list(opts),
    do: apply(module, function, merge_opts(args, opts))

  def call(module, function, args) when is_atom(module), do: apply(module, function, merge_opts(args, []))

  @doc "The source's last observed daemon block, or nil when it keeps none."
  @spec last_daemon(module() | {module(), keyword()}, keyword()) :: map() | nil
  def last_daemon(source, opts) do
    module = with {module, _} <- source, do: module
    if Code.ensure_loaded?(module) and function_exported?(module, :daemon, 1), do: call(source, :daemon, [opts])
  end

  @spec subscribe(keyword()) :: :ok
  def subscribe(_opts), do: :ok

  @spec snapshot(keyword()) :: {:error, :not_wired}
  def snapshot(_opts), do: {:error, :not_wired}
  @spec earlier(integer(), String.t(), keyword()) :: {:error, :not_wired}
  def earlier(_before, _zone, _opts), do: {:error, :not_wired}

  @spec ticket(String.t(), keyword()) :: {:error, :not_wired}
  def ticket(_id, _opts), do: {:error, :not_wired}

  defp merge_opts([], opts), do: [opts]

  defp merge_opts(args, opts) do
    if Keyword.keyword?(List.last(args)), do: List.replace_at(args, -1, Keyword.merge(opts, List.last(args))), else: args ++ [opts]
  end
end

defmodule Aiur.GitHub.ReadCache.Outcome do
  @moduledoc false

  @doc false
  @spec cacheable?(term()) :: boolean()
  def cacheable?({:ok, %{status: status, body: %{"errors" => errors}}})
      when is_integer(status) and status in 200..299 and is_list(errors) and errors != [],
      do: false

  def cacheable?({:ok, %{status: status}}) when is_integer(status) and status in 200..299, do: true
  def cacheable?(_result), do: false

  @doc false
  @spec cacheable?(term(), atom()) :: boolean()
  def cacheable?({:ok, %{status: 404, body: body}}, :repo_config) when is_map(body), do: true
  def cacheable?(result, _class), do: cacheable?(result)
end

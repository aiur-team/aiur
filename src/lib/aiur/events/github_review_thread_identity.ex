defmodule Aiur.Events.GithubReviewThreadIdentity do
  @moduledoc false

  alias Aiur.GitHub.ResourceStore

  @spec unresolved_generation(ResourceStore.key()) :: String.t() | nil
  def unresolved_generation(resource) do
    case ResourceStore.fetch(resource) do
      {:ok, %{data: %{"webhook_action" => "unresolved", "generation" => generation}}}
      when is_binary(generation) and generation != "" ->
        generation

      _other ->
        nil
    end
  end

  @spec resource_version(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resource_version(version, generation) when is_binary(generation) and generation != "" do
    if is_binary(version), do: generation <> ":" <> version, else: generation
  end

  def resource_version(version, _generation), do: version
end

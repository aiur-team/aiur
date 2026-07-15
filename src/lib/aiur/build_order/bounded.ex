defmodule Aiur.BuildOrder.Bounded do
  @moduledoc false

  @max_title_bytes 512
  @max_url_bytes 2048
  @max_github_issue_identifier_bytes 19

  @spec title(term()) :: {:ok, String.t()} | :error
  def title(value), do: text(value, @max_title_bytes)

  @spec github_url(term()) :: {:ok, String.t()} | :error
  def github_url(value) do
    with {:ok, value} <- text(value, @max_url_bytes),
         %URI{} = uri <- URI.parse(value),
         true <- safe_github_uri?(uri) do
      {:ok, URI.to_string(uri)}
    else
      _ -> :error
    end
  end

  @doc "Validates the canonical positive issue number used in a GitHub request path."
  @spec github_issue_identifier(term()) :: {:ok, String.t()} | :error
  def github_issue_identifier(value) do
    with {:ok, identifier} <- text(value, @max_github_issue_identifier_bytes),
         true <- positive_number?(identifier) do
      {:ok, identifier}
    else
      _ -> :error
    end
  end

  @spec github_issue_repository(term()) :: {:ok, %{owner: String.t(), repository: String.t()}} | :error
  def github_issue_repository(value) do
    with {:ok, reference} <- github_issue_reference(value) do
      {:ok, Map.take(reference, [:owner, :repository])}
    end
  end

  @spec github_issue_url_for(term(), term()) :: {:ok, String.t()} | :error
  def github_issue_url_for(value, %{owner: owner, repository: repository, identifier: identifier}) do
    with {:ok, url} <- github_url(value),
         {:ok, reference} <- github_issue_reference(url),
         true <- reference.kind == "issues",
         true <- same_repository?(reference, %{owner: owner, repository: repository}),
         true <- reference.identifier == identifier do
      {:ok, url}
    else
      _ -> :error
    end
  end

  def github_issue_url_for(_value, _identity), do: :error

  @spec github_issue_reference(term()) ::
          {:ok, %{owner: String.t(), repository: String.t(), kind: String.t(), identifier: String.t()}} | :error
  def github_issue_reference(value) do
    with {:ok, url} <- github_url(value),
         %URI{path: path} <- URI.parse(url),
         [owner, repository, kind, number] <- String.split(path, "/", trim: true) do
      {:ok, %{owner: owner, repository: repository, kind: kind, identifier: number}}
    else
      _ -> :error
    end
  end

  @doc """
  Validates one owner or repository component used to construct a GitHub URL.

  These values are interpolated into outbound provider requests, so whitespace,
  URL delimiters, and traversal-shaped components fail closed.
  """
  @spec github_repository_component(term()) :: {:ok, String.t()} | :error
  def github_repository_component(value) do
    with {:ok, component} <- text(value, 100),
         true <- valid_path_part?(component) do
      {:ok, component}
    else
      _ -> :error
    end
  end

  @doc "Validates the owner and repository together before provider I/O."
  @spec github_repository_components(term(), term()) ::
          {:ok, {String.t(), String.t()}} | :error
  def github_repository_components(owner, repository) do
    with {:ok, owner} <- github_repository_component(owner),
         {:ok, repository} <- github_repository_component(repository) do
      {:ok, {owner, repository}}
    else
      _ -> :error
    end
  end

  @spec same_repository?(term(), term()) :: boolean()
  def same_repository?(%{owner: owner, repository: repository}, %{
        owner: other_owner,
        repository: other_repository
      }) do
    is_binary(owner) and is_binary(repository) and is_binary(other_owner) and
      is_binary(other_repository) and
      String.downcase(owner) == String.downcase(other_owner) and
      String.downcase(repository) == String.downcase(other_repository)
  end

  def same_repository?(_left, _right), do: false

  @spec text(term(), pos_integer()) :: {:ok, String.t()} | :error
  def text(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    if String.valid?(value) and value != "" and byte_size(value) <= limit,
      do: {:ok, value},
      else: :error
  end

  def text(_value, _limit), do: :error

  defp safe_github_uri?(%URI{
         scheme: "https",
         host: host,
         userinfo: nil,
         port: port,
         query: nil,
         fragment: nil,
         path: path
       })
       when port in [nil, 443] do
    String.downcase(host || "") == "github.com" and github_issue_path?(path)
  end

  defp safe_github_uri?(_uri), do: false

  defp github_issue_path?(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [owner, repository, kind, number] when kind in ["issues", "pull"] ->
        valid_path_part?(owner) and valid_path_part?(repository) and positive_number?(number)

      _ ->
        false
    end
  end

  defp github_issue_path?(_path), do: false

  defp valid_path_part?(part), do: part not in [".", ".."] and Regex.match?(~r/^[A-Za-z0-9_.-]{1,100}$/, part)
  defp positive_number?(value), do: Regex.match?(~r/^[1-9][0-9]{0,18}$/, value)
end

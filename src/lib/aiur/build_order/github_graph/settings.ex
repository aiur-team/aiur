defmodule Aiur.BuildOrder.GitHubGraph.Settings do
  @moduledoc false

  alias Aiur.{GitHub, TrackerIdentity}
  alias Aiur.GitHub.Transport

  @member_limit 100
  @max_page_budget 4
  @max_call_budget 4

  @type repository :: {String.t(), String.t()}
  @type limits :: %{
          optional(:page_size) => pos_integer(),
          root_limit: pos_integer(),
          page_budget: pos_integer(),
          call_budget: pos_integer()
        }

  defmodule Paging do
    @moduledoc false

    @type t :: %__MODULE__{
            repository: {String.t(), String.t()} | nil,
            token: String.t() | nil,
            limits: map() | nil,
            limit: pos_integer() | nil,
            root_number: pos_integer() | nil,
            requested_root: TrackerIdentity.t() | nil,
            root: map() | nil,
            root_fingerprint: map() | nil,
            expected_total: non_neg_integer() | nil,
            cursor: String.t() | nil,
            seen_cursors: MapSet.t(),
            nodes: [map()]
          }

    defstruct [
      :repository,
      :token,
      :limits,
      :limit,
      :root_number,
      :requested_root,
      :root,
      root_fingerprint: nil,
      expected_total: nil,
      cursor: nil,
      seen_cursors: MapSet.new(),
      nodes: []
    ]
  end

  @spec configured_repository(keyword()) :: {:ok, repository()} | {:error, atom()}
  def configured_repository(opts) do
    case Keyword.get(opts, :repository) do
      {owner, repository} when is_binary(owner) and is_binary(repository) and owner != "" and repository != "" ->
        {:ok, {owner, repository}}

      nil ->
        GitHub.Config.configured_repo()

      _ ->
        {:error, :invalid_github_repo}
    end
  end

  @spec limits(keyword()) :: {:ok, limits()} | {:error, :invalid_planning_bounds}
  def limits(opts) do
    limits = %{
      root_limit: option_or_config(opts, :root_limit, &GitHub.Config.planning_root_limit/0),
      page_budget: option_or_config(opts, :page_budget, &GitHub.Config.planning_page_budget/0),
      call_budget: option_or_config(opts, :call_budget, &GitHub.Config.planning_call_budget/0)
    }

    if valid_limits?(limits) do
      {:ok, Map.put(limits, :page_size, page_size(limits, @member_limit))}
    else
      {:error, :invalid_planning_bounds}
    end
  end

  @spec initial_state(keyword()) :: map()
  def initial_state(opts) do
    %{
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      calls: 0,
      pages: 0,
      rate_limit: %{},
      page_budget: option_or_config(opts, :page_budget, &GitHub.Config.planning_page_budget/0),
      call_budget: option_or_config(opts, :call_budget, &GitHub.Config.planning_call_budget/0)
    }
  end

  @spec new_paging(repository(), String.t(), limits(), pos_integer(), TrackerIdentity.t() | nil) :: Paging.t()
  def new_paging(repository, token, limits, limit, requested_root \\ nil) do
    %Paging{
      repository: repository,
      token: token,
      limits: limits,
      limit: limit,
      root_number: requested_root_number(requested_root),
      requested_root: requested_root
    }
  end

  @spec catalog_variables(Paging.t()) :: map()
  def catalog_variables(%Paging{repository: {owner, repository}, cursor: cursor, limits: limits}) do
    %{"owner" => owner, "repo" => repository, "pageSize" => page_size(limits, limits.root_limit)}
    |> Transport.maybe_put_query("cursor", cursor)
  end

  @spec selected_variables(Paging.t()) :: map()
  def selected_variables(%Paging{
        repository: {owner, repository},
        root_number: number,
        cursor: cursor,
        limits: limits
      }) do
    %{"owner" => owner, "repo" => repository, "number" => number, "pageSize" => limits.page_size}
    |> Transport.maybe_put_query("cursor", cursor)
  end

  @spec requested_root(term(), repository()) :: {:ok, TrackerIdentity.t()} | {:error, :invalid_requested_root}
  def requested_root(%TrackerIdentity{} = root, repository) do
    with true <- TrackerIdentity.joinable?(root),
         true <- same_repository?(root, repository),
         {:ok, _number} <- positive_number(root.identifier) do
      {:ok, root}
    else
      _ -> {:error, :invalid_requested_root}
    end
  end

  def requested_root(_root, _repository), do: {:error, :invalid_requested_root}

  defp valid_limits?(%{root_limit: roots, page_budget: pages, call_budget: calls}) do
    is_integer(roots) and roots in 1..@member_limit and
      is_integer(pages) and pages in 1..@max_page_budget and
      is_integer(calls) and calls in 1..@max_call_budget
  end

  defp page_size(limits, limit) do
    slots = min(limits.page_budget, limits.call_budget)
    max(1, div(limit + slots - 1, slots))
  end

  defp requested_root_number(%TrackerIdentity{} = root) do
    case positive_number(root.identifier) do
      {:ok, number} -> number
      {:error, _reason} -> nil
    end
  end

  defp requested_root_number(_root), do: nil
  defp positive_number(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_root}
    end
  end

  defp positive_number(_value), do: {:error, :invalid_root}

  defp same_repository?(
         %TrackerIdentity{owner: owner, repository: repository},
         {expected_owner, expected_repository}
       ) do
    String.downcase(owner) == String.downcase(expected_owner) and
      String.downcase(repository) == String.downcase(expected_repository)
  end

  defp same_repository?(_root, _repository), do: false

  defp option_or_config(opts, key, config_fun) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: config_fun.()
  end
end

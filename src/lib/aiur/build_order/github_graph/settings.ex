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

  @spec authority(keyword()) :: {:ok, repository(), limits()} | {:error, atom()}
  def authority(opts) do
    with {:ok, repository} <- GitHub.Config.configured_repo(),
         {:ok, limits} <- limits(),
         :ok <- configured_options?(opts, repository, limits) do
      {:ok, repository, limits}
    end
  end

  @spec limits() :: {:ok, limits()} | {:error, :invalid_planning_bounds}
  def limits do
    limits = %{
      root_limit: GitHub.Config.planning_root_limit(),
      page_budget: GitHub.Config.planning_page_budget(),
      call_budget: GitHub.Config.planning_call_budget()
    }

    if valid_limits?(limits) do
      {:ok, Map.put(limits, :page_size, page_size(limits, @member_limit))}
    else
      {:error, :invalid_planning_bounds}
    end
  end

  @spec initial_state(keyword(), limits()) :: map()
  def initial_state(opts, limits) do
    %{
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      calls: 0,
      pages: 0,
      rate_limit: %{},
      page_budget: limits.page_budget,
      call_budget: limits.call_budget
    }
  end

  @spec initial_state(keyword()) :: map()
  def initial_state(opts), do: %{request_fun: Keyword.get(opts, :request_fun), calls: 0, pages: 0, rate_limit: %{}}

  @spec new_paging(repository(), String.t(), limits(), pos_integer(), TrackerIdentity.t() | nil) :: map()
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

  @spec catalog_variables(map()) :: map()
  def catalog_variables(%Paging{repository: {owner, repository}, cursor: cursor, limits: limits}) do
    %{"owner" => owner, "repo" => repository, "pageSize" => page_size(limits, limits.root_limit)}
    |> Transport.maybe_put_query("cursor", cursor)
  end

  @spec selected_variables(map()) :: map()
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
    if valid_requested_root?(root, repository) do
      {:ok, root}
    else
      {:error, :invalid_requested_root}
    end
  end

  def requested_root(_root, _repository), do: {:error, :invalid_requested_root}

  defp valid_limits?(%{root_limit: roots, page_budget: pages, call_budget: calls}) do
    valid_limit?(roots, @member_limit) and
      valid_limit?(pages, @max_page_budget) and
      valid_limit?(calls, @max_call_budget)
  end

  defp valid_limit?(value, maximum) when is_integer(value) and value > 0 and value <= maximum, do: true
  defp valid_limit?(_value, _maximum), do: false

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

  defp valid_requested_root?(root, repository) do
    TrackerIdentity.joinable?(root) and
      same_repository?(root, repository) and
      match?({:ok, _number}, positive_number(root.identifier))
  end

  defp configured_options?(opts, repository, limits) do
    [
      repository_option?(opts, repository),
      limit_option?(opts, :root_limit, limits.root_limit),
      limit_option?(opts, :page_budget, limits.page_budget),
      limit_option?(opts, :call_budget, limits.call_budget)
    ]
    |> Enum.find(:ok, &(&1 != :ok))
  end

  defp repository_option?(opts, {owner, repository}) do
    case Keyword.fetch(opts, :repository) do
      :error ->
        :ok

      {:ok, {requested_owner, requested_repository}}
      when is_binary(requested_owner) and is_binary(requested_repository) ->
        if String.downcase(requested_owner) == String.downcase(owner) and
             String.downcase(requested_repository) == String.downcase(repository),
           do: :ok,
           else: {:error, :invalid_planning_authority}

      _ ->
        {:error, :invalid_planning_authority}
    end
  end

  defp limit_option?(opts, key, configured) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, ^configured} -> :ok
      _ -> {:error, :invalid_planning_authority}
    end
  end
end

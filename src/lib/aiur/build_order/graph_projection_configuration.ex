defmodule Aiur.BuildOrder.GraphProjection.Configuration do
  @moduledoc false

  alias Aiur.BuildOrder.{GitHubGraph.Settings, TicketDetail}
  alias Aiur.BuildOrder.GraphProjection.Options

  @spec snapshot(map(), pos_integer() | nil) :: {:ok, map()} | {:error, :configuration}
  def snapshot(%{authority_snapshot: snapshot} = state, notified_generation)
      when is_function(snapshot, 0) do
    snapshot.()
    |> normalize_snapshot(state, notified_generation)
  rescue
    _error -> {:error, :configuration}
  catch
    _kind, _reason -> {:error, :configuration}
  end

  def snapshot(state, notified_generation) do
    with {:ok, repository, generation} <-
           TicketDetail.configured_repository_snapshot(repository_opts(state, notified_generation)),
         {:ok, limits} <- Settings.limits(),
         {:ok, runtime_options} <- runtime_options(state) do
      {:ok, build_snapshot(repository, generation, limits, runtime_options)}
    else
      _ -> {:error, :configuration}
    end
  end

  defp normalize_snapshot({:ok, snapshot}, state, notified_generation),
    do: normalize_snapshot(snapshot, state, notified_generation)

  defp normalize_snapshot(%{repository: repository} = snapshot, state, notified_generation) do
    limits = %{
      root_limit: Map.get(snapshot, :root_limit, state.root_limit),
      page_budget: Map.get(snapshot, :page_budget, state.page_budget),
      call_budget: Map.get(snapshot, :call_budget, state.call_budget)
    }

    options = Map.get(snapshot, :options, [])
    generation = Map.get(snapshot, :generation, notified_generation || state.configuration_generation)

    if valid_repository?(repository) and valid_limits?(limits) and is_list(options) do
      {:ok, build_snapshot(repository, generation, limits, options)}
    else
      {:error, :configuration}
    end
  end

  defp normalize_snapshot(_snapshot, _state, _notified_generation), do: {:error, :configuration}

  defp build_snapshot(repository, generation, limits, options) do
    %{
      repository: repository,
      generation: normalize_generation(generation),
      fingerprint: authority_fingerprint(repository, limits),
      limits: limits,
      policy: Options.policy_options(options)
    }
  end

  defp runtime_options(%{runtime_options: options}) when is_function(options, 0) do
    case options.() do
      values when is_list(values) -> {:ok, values}
      _values -> {:error, :configuration}
    end
  rescue
    _error -> {:error, :configuration}
  catch
    _kind, _reason -> {:error, :configuration}
  end

  defp repository_opts(state, notified_generation) do
    []
    |> maybe_put(:configured_repo, state.configured_repo)
    |> maybe_put(:configuration_snapshot, state.configuration_snapshot)
    |> maybe_put(:configuration_generation, notified_generation || state.configuration_generation)
  end

  defp authority_fingerprint({owner, repository}, limits) do
    {String.downcase(owner), String.downcase(repository), limits.root_limit, limits.page_budget, limits.call_budget}
  end

  defp valid_repository?({owner, repository}), do: valid_name?(owner) and valid_name?(repository)
  defp valid_repository?(_repository), do: false
  defp valid_name?(value), do: is_binary(value) and String.trim(value) != "" and not String.contains?(value, "/")

  defp valid_limits?(%{root_limit: roots, page_budget: pages, call_budget: calls}) do
    valid_limit?(roots, 100) and valid_limit?(pages, 4) and valid_limit?(calls, 4)
  end

  defp valid_limit?(value, maximum), do: is_integer(value) and value > 0 and value <= maximum
  defp normalize_generation(value) when is_integer(value) and value > 0, do: value
  defp normalize_generation(_value), do: :unknown
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

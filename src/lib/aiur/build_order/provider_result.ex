defmodule Aiur.BuildOrder.ProviderResult do
  @moduledoc "A bounded Build Order candidate and its safe GitHub read evidence."

  alias Aiur.BuildOrder.Diagnostic

  @type candidate :: Aiur.BuildOrder.Catalog.t() | Aiur.BuildOrder.SelectedRoot.t() | nil
  @type status :: :complete | :failed
  @type t :: %__MODULE__{
          status: status(),
          candidate: candidate(),
          calls: non_neg_integer(),
          pages: non_neg_integer(),
          rate_limit: map(),
          error: term() | nil,
          diagnostics: [Diagnostic.t()]
        }

  defstruct status: :failed,
            candidate: nil,
            calls: 0,
            pages: 0,
            rate_limit: %{},
            error: nil,
            diagnostics: []

  @spec complete(candidate(), keyword()) :: t()
  def complete(candidate, opts \\ []) do
    %__MODULE__{
      status: :complete,
      candidate: candidate,
      calls: count(opts, :calls),
      pages: count(opts, :pages),
      rate_limit: rate_limit(opts),
      diagnostics: diagnostics(opts)
    }
  end

  @spec failed(term(), keyword()) :: t()
  def failed(reason, opts \\ []) do
    %__MODULE__{
      candidate: Keyword.get(opts, :candidate),
      calls: count(opts, :calls),
      pages: count(opts, :pages),
      rate_limit: rate_limit(opts),
      error: safe_error(reason),
      diagnostics: diagnostics(opts, [Diagnostic.new(:provider_unavailable)])
    }
  end

  @spec complete?(term()) :: boolean()
  def complete?(%__MODULE__{status: :complete}), do: true
  def complete?(_result), do: false

  defp count(opts, key) do
    case Keyword.get(opts, key, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp rate_limit(opts) do
    opts
    |> Keyword.get(:rate_limit, %{})
    |> Map.take([:cost, :limit, :remaining, :reset_at, :retry_after, :poll_interval])
  rescue
    _ -> %{}
  end

  defp diagnostics(opts, default \\ []) do
    case Keyword.get(opts, :diagnostics, default) do
      values when is_list(values) -> Enum.filter(values, &match?(%Diagnostic{}, &1))
      _ -> default
    end
  end

  defp safe_error({:github, classification, detail}) when is_atom(classification) and is_map(detail) do
    {:github, classification, Map.take(detail, [:status, :remaining, :reset_at, :retry_after, :poll_interval])}
  end

  defp safe_error({:aiur, :locally_held, %{reason: reason, resource: "graphql"} = detail})
       when reason in [:shared_budget, :actor_budget] do
    {:aiur, :locally_held, Map.take(detail, [:reason, :resource, :reset_at])}
  end

  defp safe_error(:graphql_partial), do: :graphql_partial
  defp safe_error({:github_graphql_errors, _errors}), do: :graphql_partial
  defp safe_error(reason) when reason in [:invalid_connection, :invalid_graphql_response, :invalid_root], do: :schema
  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :provider_error
end

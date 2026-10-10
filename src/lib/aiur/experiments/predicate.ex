defmodule Aiur.Experiments.Predicate do
  @moduledoc "Closed, data-only predicates over cohort attributes."
  @attributes ~w(aiur_version backend model epic feature_tags config_hash complexity)
  @operators ~w(eq neq in prefix exists)

  @spec attribute?(term()) :: boolean()
  def attribute?(attribute), do: attribute in @attributes or (is_binary(attribute) and Regex.match?(~r/^tags\.[a-zA-Z0-9_-]+$/, attribute))

  @spec validate(term()) :: [map()]
  def validate(predicate), do: validate(predicate, "predicate")

  @spec validate(term(), String.t()) :: [map()]
  def validate(%{"all" => children} = node, path) when map_size(node) == 1 and is_list(children), do: children_errors(children, path <> ".all")
  def validate(%{"any" => children} = node, path) when map_size(node) == 1 and is_list(children), do: children_errors(children, path <> ".any")
  def validate(%{"not" => child} = node, path) when map_size(node) == 1, do: validate(child, path <> ".not")

  def validate(%{"attr" => attr, "op" => op} = node, path) do
    errors = if attribute?(attr), do: [], else: [error(path <> ".attr", "unknown cohort attribute")]
    errors = if op in @operators, do: errors, else: errors ++ [error(path <> ".op", "unknown predicate operator")]
    errors = if Enum.all?(Map.keys(node), &(&1 in ~w(attr op value))), do: errors, else: errors ++ [error(path, "unknown predicate field")]
    errors ++ value_errors(node, op, path)
  end

  def validate(_, path), do: [error(path, "expected all, any, not, or an attribute predicate")]

  @spec matches?(term(), map()) :: boolean()
  def matches?(predicate, attrs) do
    validate(predicate) == [] and match_node(predicate, attrs)
  end

  defp children_errors(children, path), do: children |> Enum.with_index() |> Enum.flat_map(fn {child, index} -> validate(child, "#{path}.#{index}") end)
  defp value_errors(%{"value" => value}, "in", path) when not is_list(value), do: [error(path <> ".value", "in requires a list")]
  defp value_errors(%{"value" => value}, "prefix", path) when not is_binary(value), do: [error(path <> ".value", "prefix requires a string")]
  defp value_errors(%{"value" => value}, "exists", path) when not is_boolean(value), do: [error(path <> ".value", "exists requires a boolean")]
  defp value_errors(node, op, path) when op in ~w(eq neq in prefix), do: if(Map.has_key?(node, "value"), do: [], else: [error(path <> ".value", "is required")])
  defp value_errors(_, _, _), do: []
  defp error(path, message), do: %{path: path, message: message}

  defp match_node(%{"all" => children}, attrs), do: Enum.all?(children, &match_node(&1, attrs))
  defp match_node(%{"any" => children}, attrs), do: Enum.any?(children, &match_node(&1, attrs))
  defp match_node(%{"not" => child}, attrs), do: not match_node(child, attrs)

  defp match_node(%{"attr" => attr, "op" => op} = node, attrs) do
    found = lookup(attrs, String.split(attr, "."))
    value = Map.get(node, "value")

    case {op, found} do
      {"exists", result} -> result != :error == Map.get(node, "value", true)
      {"eq", {:ok, actual}} -> actual == value
      {"neq", {:ok, actual}} -> actual != value
      {"in", {:ok, actual}} -> actual in value
      {"prefix", {:ok, actual}} when is_binary(actual) -> String.starts_with?(actual, value)
      _ -> false
    end
  end

  defp lookup(value, []), do: {:ok, value}

  defp lookup(attrs, [key | rest]) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> lookup(value, rest)
      :error -> :error
    end
  end

  defp lookup(_, _), do: :error
end

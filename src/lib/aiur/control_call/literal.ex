defmodule Aiur.ControlCall.Literal do
  @moduledoc false

  @max_depth 6

  @spec convert(list()) :: {:ok, list()} | {:error, atom()}
  def convert(args), do: convert_list(args, 0)

  @spec validate_raw_option_keys(map(), list()) :: :ok | {:error, :option_not_allowed}
  def validate_raw_option_keys(%{options: options}, args) do
    Enum.reduce_while(args, :ok, fn
      keyword, :ok when is_list(keyword) ->
        if option_not_allowed?(keyword, options), do: {:halt, {:error, :option_not_allowed}}, else: {:cont, :ok}

      _value, :ok ->
        {:cont, :ok}
    end)
  end

  defp option_not_allowed?(keyword, options),
    do: Keyword.keyword?(keyword) and Enum.any?(keyword, fn {key, _value} -> not Map.has_key?(options, key) end)

  defp convert_list(values, depth) when depth <= @max_depth and is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case literal(value, depth + 1) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp convert_list(_values, _depth), do: {:error, :non_literal_argument}

  defp literal(value, depth) when depth <= @max_depth and is_binary(value), do: {:ok, value}
  defp literal(value, depth) when depth <= @max_depth and is_integer(value), do: {:ok, value}
  defp literal(value, depth) when depth <= @max_depth and is_float(value), do: {:ok, value}
  defp literal(value, depth) when depth <= @max_depth and (is_boolean(value) or is_nil(value) or is_atom(value)), do: {:ok, value}
  defp literal({:__aliases__, _, _}, _depth), do: {:error, :non_literal_argument}

  # Feature commands emit only this fixed record shape for epic metadata.
  defp literal({:%{}, _, pairs}, depth) when depth < @max_depth and is_list(pairs) do
    with {:ok, entries} <- convert_map_pairs(pairs, depth + 1),
         map <- Map.new(entries),
         true <- valid_epic(map) do
      {:ok, map}
    else
      _ -> {:error, :non_literal_argument}
    end
  end

  defp literal({{:., _, [{:__aliases__, _, [:Base]}, :decode64!]}, _, [arg]}, depth) when depth < @max_depth do
    with {:ok, encoded} <- literal(arg, depth + 1), true <- is_binary(encoded) do
      case Base.decode64(encoded) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, :non_literal_argument}
      end
    else
      _ -> {:error, :non_literal_argument}
    end
  end

  defp literal({left, right}, depth) when depth < @max_depth do
    with {:ok, left_value} <- literal(left, depth + 1), {:ok, right_value} <- literal(right, depth + 1), do: {:ok, {left_value, right_value}}
  end

  defp literal({:{}, _, [left, right]}, depth) when depth < @max_depth do
    with {:ok, left_value} <- literal(left, depth + 1), {:ok, right_value} <- literal(right, depth + 1), do: {:ok, {left_value, right_value}}
  end

  defp literal(list, depth) when is_list(list) and depth < @max_depth do
    convert_list(list, depth)
  end

  defp literal(_value, _depth), do: {:error, :non_literal_argument}

  defp convert_map_pairs(pairs, depth) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        case literal(value, depth) do
          {:ok, converted} -> {:cont, {:ok, [{key, converted} | acc]}}
          error -> {:halt, error}
        end

      _pair, _acc ->
        {:halt, {:error, :non_literal_argument}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  @spec validate_arguments(map(), list()) :: :ok | {:error, atom()}
  def validate_arguments(%{positional: positional, options: options}, args) do
    with :ok <- validate_positional(positional, args),
         do: validate_keyword_arguments(args, options)
  end

  defp validate_positional(positional, args) when length(positional) == length(args) do
    Enum.zip(args, positional)
    |> Enum.reduce_while(:ok, fn {value, constraint}, :ok -> if valid?(value, constraint), do: {:cont, :ok}, else: {:halt, {:error, :non_literal_argument}} end)
  end

  defp validate_positional(_positional, _args), do: {:error, :non_literal_argument}

  defp validate_keyword_arguments(args, options) do
    Enum.reduce_while(args, :ok, fn arg, :ok -> keyword_result(arg, options) end)
  end

  defp validate_keyword_argument(value, options) when is_list(value) do
    if Keyword.keyword?(value), do: validate_keyword_pairs(value, options), else: :ok
  end

  defp validate_keyword_argument(_value, _options), do: :ok

  defp keyword_result(arg, options) do
    case validate_keyword_argument(arg, options) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp validate_keyword_pairs(value, options) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok -> validate_option(key, item, options) end)
  end

  defp validate_option(key, item, options) do
    case Map.fetch(options, key) do
      :error -> {:halt, {:error, :option_not_allowed}}
      {:ok, constraint} -> if valid?(item, constraint), do: {:cont, :ok}, else: {:halt, {:error, :non_literal_argument}}
    end
  end

  defp valid?(_value, :any), do: true
  defp valid?(value, :atom), do: is_atom(value)
  defp valid?(value, {:nullable, constraint}), do: is_nil(value) or valid?(value, constraint)
  defp valid?(value, {:regex, regex}), do: is_binary(value) and Regex.match?(regex, value)
  defp valid?(value, :boolean), do: is_boolean(value)
  defp valid?(value, :string), do: is_binary(value)
  defp valid?(value, :non_empty_string), do: is_binary(value) and value != ""
  defp valid?(value, :positive), do: is_integer(value) and value > 0
  defp valid?(value, {:range, low, high}), do: is_integer(value) and value >= low and value <= high
  defp valid?(value, :non_negative), do: is_integer(value) and value >= 0
  defp valid?(value, :integer), do: is_integer(value)
  defp valid?(value, :literal_list), do: is_list(value)
  defp valid?(value, :string_list), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp valid?(value, :keyword), do: is_list(value) and Keyword.keyword?(value)
  defp valid?(value, :feature_ids), do: is_list(value) and length(value) in 1..200 and Enum.all?(value, &(is_integer(&1) and &1 in 1..2_147_483_647))
  defp valid?(value, :ticket_id_strings), do: is_list(value) and length(value) in 1..200 and Enum.all?(value, &ticket_id_string?/1)
  defp valid?(value, :executor_env), do: is_list(value) and Enum.all?(value, &valid_executor_env_entry?/1)
  defp valid?(value, :epic_list), do: is_list(value) and value != [] and Enum.all?(value, &valid_epic/1)
  defp valid?(value, :quarter_hour), do: valid_quarter_hour?(value)
  defp valid?(value, :estimate_reason), do: is_binary(value) and String.length(value) in 1..500 and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  defp valid?(value, :estimate_actor), do: is_binary(value) and byte_size(value) in 1..64 and Regex.match?(~r/^[A-Za-z0-9._:@-]+$/, value)
  defp valid?(value, {:enum, choices}), do: value in choices
  defp valid?(value, {:one_of, constraints}), do: Enum.any?(constraints, &valid?(value, &1))
  defp valid?(_value, _constraint), do: false

  defp valid_epic(%{key: key, label: label} = epic),
    do: map_size(epic) == 2 and is_binary(key) and key != "" and is_binary(label) and label != ""

  defp valid_epic(_epic), do: false

  defp valid_quarter_hour?(value) when is_binary(value) do
    if Regex.match?(~r/^[0-9]{1,3}(\.(0|00|25|5|50|75))?$/, value) do
      case Float.parse(value) do
        {hours, ""} -> hours > 0 and hours <= 999 and abs(hours * 4 - round(hours * 4)) < 1.0e-9
        _ -> false
      end
    else
      false
    end
  end

  defp valid_quarter_hour?(_value), do: false

  defp ticket_id_string?(value) when is_binary(value), do: Regex.match?(~r/^[1-9][0-9]*$/, value)

  defp ticket_id_string?(_value), do: false

  defp valid_executor_env_entry?({key, value}) when is_binary(key) and is_binary(value),
    do: key in ["CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR", "CLAUDE_PID", "CLAUDE_CODE_CHILD_SESSION", "CODEX_THREAD_ID", "PWD"]

  defp valid_executor_env_entry?(_entry), do: false
end

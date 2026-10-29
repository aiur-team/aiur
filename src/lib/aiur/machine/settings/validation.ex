defmodule Aiur.Machine.Settings.Validation do
  @moduledoc false
  import Ecto.Changeset

  @spec cast(struct(), map(), keyword()) :: Ecto.Changeset.t()
  def cast(%module{} = schema, attrs, opts \\ []) do
    embeds = module.__schema__(:embeds)
    fields = module.__schema__(:fields) -- embeds
    keys = Enum.map(fields ++ embeds, &Atom.to_string/1)
    changeset = cast(schema, Map.take(attrs, keys), fields, empty_values: [])

    changeset =
      if Keyword.get(opts, :nullable, false) do
        changeset
      else
        Enum.reduce(fields, changeset, &nonnull(&2, &1, "must not be null"))
      end

    Enum.reduce(embeds, changeset, fn field, acc ->
      acc = cast_embed(acc, field)
      nonnull(acc, field, "must be a mapping")
    end)
  end

  defp nonnull(changeset, field, message) do
    if is_nil(get_field(changeset, field)), do: add_error(changeset, field, message), else: changeset
  end

  @spec unknown_keys(map(), module(), String.t()) :: [{String.t(), String.t()}]
  def unknown_keys(attrs, module, prefix \\ "") do
    Enum.flat_map(attrs, fn {key, value} ->
      field = Enum.find(module.__schema__(:fields), &(Atom.to_string(&1) == key))
      path = prefix <> if(is_binary(key), do: key, else: inspect(key))
      nested_errors(field, value, module, path, prefix)
    end)
  end

  defp nested_errors(nil, _value, _module, _path, ""), do: []
  defp nested_errors(nil, _value, _module, path, _prefix), do: [{path, "unknown key"}]

  defp nested_errors(field, value, module, path, _prefix) do
    case module.__schema__(:embed, field) do
      %{related: related} when is_map(value) -> unknown_keys(value, related, path <> ".")
      _ -> []
    end
  end

  @spec errors(Ecto.Changeset.t()) :: [{String.t(), String.t()}]
  def errors(changeset) do
    changeset
    |> traverse_errors(&format_error/1)
    |> flatten("")
  end

  defp format_error({message, opts}), do: Enum.reduce(opts, message, &interpolate/2)

  defp interpolate({key, value}, message) when is_binary(value) or is_number(value), do: String.replace(message, "%{#{key}}", to_string(value))
  defp interpolate(_option, message), do: message

  defp flatten(errors, prefix) do
    Enum.flat_map(errors, fn {key, value} ->
      path = prefix <> to_string(key)
      if is_map(value), do: flatten(value, path <> "."), else: Enum.map(value, &{path, &1})
    end)
  end

  @spec check(atom(), boolean(), String.t()) :: keyword(String.t())
  def check(_key, true, _message), do: []
  def check(key, false, message), do: [{key, message}]

  @spec ip?(String.t()) :: boolean()
  def ip?(value), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(value)))

  @spec resolvable?(String.t()) :: boolean()
  def resolvable?(value) do
    ip?(value) or
      (dns?(value) and
         (match?({:ok, _}, :inet.getaddr(String.to_charlist(value), :inet)) or
            match?({:ok, _}, :inet.getaddr(String.to_charlist(value), :inet6))))
  end

  @spec dns?(String.t()) :: boolean()
  def dns?(value) do
    byte_size(value) <= 253 and
      Enum.all?(String.split(value, "."), &Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, &1)) and not ip?(value)
  end

  @spec endpoint?(String.t()) :: boolean()
  def endpoint?(value) when is_binary(value) do
    uri = URI.parse(value)

    uri.scheme in ["http", "https"] and valid_authority?(uri) and no_suffix?(uri)
  rescue
    ArgumentError -> false
  end

  def endpoint?(_value), do: false

  defp valid_authority?(uri) do
    is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
      is_integer(uri.port) and uri.port in 1..65_535 and (ip?(uri.host) or dns?(uri.host))
  end

  defp no_suffix?(uri), do: uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment)

  @spec cidr?(String.t()) :: boolean()
  def cidr?(value) when is_binary(value) do
    with [address, bits] <- String.split(value, "/"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
         {prefix, ""} <- Integer.parse(bits) do
      prefix > 0 and prefix <= if(tuple_size(ip) == 4, do: 32, else: 128)
    else
      _ -> false
    end
  end

  def cidr?(_value), do: false
end

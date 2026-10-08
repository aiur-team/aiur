defmodule Aiur.Identity.Machine do
  @moduledoc """
  Ensures one random, durable identity before daemon supervision starts.
  A damaged or inaccessible identity degrades boot; it is never regenerated.
  """

  require Logger

  alias Aiur.Identity.Store

  @key {__MODULE__, :boot_result}
  @context_key {__MODULE__, :boot_context}

  @type identity :: %{machine_id: String.t(), machine_label: String.t(), created_at: String.t()}
  @type result :: {:ok, identity()} | {:degraded, :identity_unreadable | :identity_uncreatable, term()}

  @spec ensure(keyword()) :: result()
  def ensure(opts \\ []) do
    dir = Store.dir(opts)
    result = load(dir, opts)
    cache(result, dir)
  rescue
    error -> cache({:degraded, :identity_uncreatable, error}, Keyword.get(opts, :dir, "unresolved machine directory"))
  end

  defp cache(result, dir) do
    announced =
      case :persistent_term.get(@context_key, nil) do
        {^dir, announced} -> announced
        _ -> :atomics.new(1, [])
      end

    if :persistent_term.get(@key, :not_loaded) != result, do: :persistent_term.put(@key, result)
    if :persistent_term.get(@context_key, nil) != {dir, announced}, do: :persistent_term.put(@context_key, {dir, announced})
    result
  end

  defp load(dir, opts) do
    case Store.read(dir) do
      {:ok, identity} -> {:ok, identity}
      {:error, :enoent} -> create(dir, opts)
      {:error, reason} -> {:degraded, :identity_unreadable, reason}
    end
  rescue
    error -> {:degraded, :identity_uncreatable, error}
  catch
    kind, reason -> {:degraded, :identity_uncreatable, {kind, reason}}
  end

  defp create(dir, opts) do
    case Store.create(dir, new_identity(opts)) do
      :ok ->
        case Store.read(dir) do
          {:ok, identity} -> {:ok, identity}
          {:error, reason} -> {:degraded, :identity_unreadable, reason}
        end

      {:error, reason} ->
        {:degraded, :identity_uncreatable, reason}
    end
  end

  defp new_identity(opts) do
    random = Keyword.get(opts, :random_fun, &:crypto.strong_rand_bytes/1)
    <<_::128>> = bytes = random.(16)
    hostname = Keyword.get(opts, :hostname_fun, &:inet.gethostname/0)

    %{
      schema_version: 1,
      machine_id: Base.encode32(bytes, case: :lower, padding: false),
      machine_label: label(hostname.()),
      created_at: DateTime.to_iso8601(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
    }
  end

  defp label({:ok, host}) do
    host
    |> to_string()
    |> String.split(".")
    |> hd()
    |> String.replace(~r/\p{Cc}/u, "")
    |> String.codepoints()
    |> Enum.reduce_while("", fn point, acc ->
      if byte_size(acc <> point) <= 63, do: {:cont, acc <> point}, else: {:halt, acc}
    end)
  end

  defp label({:error, _reason}), do: "aiur"

  @spec current() :: result() | :not_loaded
  def current, do: :persistent_term.get(@key, :not_loaded)

  @spec announce_degraded(keyword()) :: :ok
  def announce_degraded(opts \\ []) do
    case current() do
      {:degraded, reason, _detail} ->
        {dir, announced} = :persistent_term.get(@context_key)

        announce(dir, announced, reason, opts)

      _ ->
        :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("Could not announce degraded machine identity: #{Exception.message(error)}")
      :ok
  end

  defp announce(dir, announced, reason, opts) do
    if :atomics.compare_exchange(announced, 1, 0, 1) == :ok do
      emit = Keyword.get(opts, :emit_fun, &Aiur.Alerts.emit_system/2)
      suffix = if reason == :identity_unreadable, do: "unreadable", else: "uncreatable"
      emit.("system.identity." <> suffix, needs_attention: true, message: "Machine identity #{suffix} in #{dir}; automatic regeneration is disabled")
    end
  end
end

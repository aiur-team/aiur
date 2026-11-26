defmodule Aiur.EpicCLI do
  @moduledoc """
  `aiur epic` — epic records above features, plus the deprecated lane spellings.

  `create`, `edit`, `add`, `remove`, `show` and `list` read and write the epic
  journal beside the feature registry. `set`, `clear` and `confirm` are the
  deprecated spelling of `aiur lane`, so they run `Aiur.LaneCLI` over the lane
  override store and keep their output and exit codes.
  """

  alias Aiur.BuildOrder.Epics.EpicData
  alias Aiur.BuildOrder.Features
  alias Aiur.BuildOrder.Features.FeatureData
  alias Aiur.EpicCLI.Output

  @lane_actions [:set, :clear, :confirm]
  @record_actions [:create, :edit, :add, :remove, :show, :list]
  @writes [:create, :edit, :add, :remove]

  @spec run(keyword()) :: non_neg_integer()
  def run(opts) do
    case Keyword.get(opts, :action) do
      action when action in @lane_actions -> Aiur.LaneCLI.run(opts)
      action when action in @record_actions -> records(opts)
      _other -> records(opts)
    end
  end

  @doc "Runs one epic-record command and prints its result."
  @spec records(keyword()) :: non_neg_integer()
  def records(opts) do
    args = Map.new(opts)

    case execute(args, opts) do
      {:ok, result} -> print({:ok, result}, args)
      {:usage, message} -> print({:usage, message}, args)
      {:error, reason} -> print({:error, reason}, args)
    end
  end

  defp execute(args, opts) do
    with :ok <- validate(args),
         {:ok, result} <- apply_op(args, context(args, opts)) do
      {:ok, Map.put(result, :schema_version, 1)}
    end
  end

  defp context(args, opts) do
    who = args[:who]
    Keyword.merge(opts, actor: "cli:" <> to_string(who), source: "cli:" <> to_string(who))
  end

  @doc "Applies one epic-record command against the registry."
  @spec apply_op(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:usage, String.t()}
  def apply_op(%{action: :list} = args, context), do: list(args, context)

  def apply_op(%{action: :show} = args, context) do
    case Map.get(args, :slug) do
      nil -> list(args, context)
      slug -> show(Map.put(args, :slug, slug), context)
    end
  end

  def apply_op(%{action: action} = args, context) when action in @writes, do: write(action, args, context)
  def apply_op(_args, _context), do: {:usage, "epic requires create, edit, add, remove, show or list"}

  defp list(args, context) do
    with {:ok, %{epics: epics}} <- Features.epics(server(context)) do
      {:ok, %{command: "epic list", epics: epics, json: args[:json]}}
    end
  end

  defp show(%{slug: slug} = args, context) do
    with {:ok, epic} <- Features.epic(slug, server(context)),
         {:ok, snapshot} <- Features.snapshot(server(context)) do
      {:ok, %{command: "epic show", epic: epic, features: snapshot.features, json: args[:json]}}
    end
  end

  defp write(:create, args, context) do
    with {:ok, result} <- Features.epic_create(args.slug, attrs(args, [:label, :icon, :hue, :root]), meta(context)) do
      {:ok, written("epic create", args.slug, result, args[:json], context)}
    end
  end

  defp write(:edit, args, context) do
    with {:ok, result} <- Features.epic_edit(args.slug, attrs(args, [:label, :icon, :hue]), meta(context)) do
      {:ok, written("epic edit", args.slug, result, args[:json], context)}
    end
  end

  defp write(action, args, context) when action in [:add, :remove] do
    writer = if action == :add, do: &Features.epic_add/3, else: &Features.epic_remove/3

    with {:ok, result} <- writer.(args.slug, args.features, meta(context)) do
      # The requested slugs, not the epic's list afterwards, so a removal still
      # names what it removed.
      {:ok, Map.put(written("epic #{action}", args.slug, result, args[:json], context), :features, args.features)}
    end
  end

  defp written(command, slug, result, json, context) do
    epic =
      case Features.epic(slug, server(context)) do
        {:ok, epic} -> epic
        _error -> nil
      end

    %{command: command, epic: epic, changed: Map.get(result, :changed, []), generation: Map.get(result, :generation), json: json}
  end

  defp attrs(args, keys) do
    keys
    |> Enum.reduce(%{}, fn key, acc -> if Map.has_key?(args, key) and not is_nil(args[key]), do: Map.put(acc, key, args[key]), else: acc end)
  end

  defp meta(context), do: Keyword.take(context, [:actor, :source, :server, :timeout])
  defp server(context), do: Keyword.take(context, [:server, :timeout])

  defp validate(args) do
    action = args[:action]

    with :ok <- known_action(action),
         :ok <- valid_slug(action, args[:slug]),
         :ok <- valid_values(args),
         :ok <- required(action, args) do
      valid_writer(action, args)
    end
  end

  defp known_action(action) when action in @record_actions, do: :ok
  defp known_action(_action), do: usage("epic requires create, edit, add, remove, show or list")
  defp valid_slug(:list, _slug), do: :ok
  defp valid_slug(:show, nil), do: :ok

  defp valid_slug(_action, slug), do: if(EpicData.slug?(slug), do: :ok, else: usage("invalid epic slug"))

  defp valid_values(args) do
    [valid_hue(args), valid_label(args), valid_icon(args), valid_root(args), valid_features(args)]
    |> Enum.find(:ok, &match?({:usage, _}, &1))
  end

  defp valid_hue(args), do: check(args, :hue, "hue must be 0 to 359", &FeatureData.hue?/1)
  defp valid_label(args), do: check(args, :label, "invalid label", &FeatureData.text?(&1, 80))
  defp valid_icon(args), do: check(args, :icon, "icon must be a Heroicons v2 outline name", &Aiur.Heroicons.valid?/1)
  defp valid_root(args), do: check(args, :root, "root must be an issue number below 2147483648", &valid_root?/1)

  defp valid_features(args) do
    if valid_features?(args[:features]), do: :ok, else: usage("epic add and remove need 1 to 200 feature slugs")
  end

  defp check(args, key, message, valid?) do
    if Map.has_key?(args, key) and not valid?.(args[key]), do: usage(message), else: :ok
  end

  defp valid_root?(value), do: is_integer(value) and value > 0 and value < 2_147_483_648
  defp valid_features?(nil), do: true

  defp valid_features?(features) do
    is_list(features) and features != [] and length(features) <= 200 and Enum.all?(features, &FeatureData.slug?/1)
  end

  defp required(:create, args), do: if(Map.has_key?(args, :label), do: :ok, else: usage("epic create requires --label"))
  defp required(:edit, args), do: if(Enum.any?([:label, :icon, :hue], &Map.has_key?(args, &1)), do: :ok, else: usage("epic edit requires at least one change"))
  defp required(action, args) when action in [:add, :remove], do: if(is_list(args[:features]) and args[:features] != [], do: :ok, else: usage("epic #{action} requires feature slugs"))
  defp required(_action, _args), do: :ok

  defp valid_writer(:show, _args), do: :ok
  defp valid_writer(:list, _args), do: :ok

  defp valid_writer(_action, args) do
    if is_binary(args[:who]) and Regex.match?(~r/\A[A-Za-z0-9._-]{1,64}\z/, args[:who]), do: :ok, else: usage("write requires a valid --as or USER")
  end

  defp print({:ok, result}, args) do
    IO.puts(if(args[:json], do: Jason.encode!(Aiur.JSONSafe.normalize(result)), else: Output.render(result)))
    0
  end

  defp print({kind, reason}, args) when kind in [:error, :usage] do
    message = if kind == :usage, do: reason, else: Output.error(reason)
    if args[:json], do: IO.puts(Jason.encode!(Aiur.JSONSafe.normalize(%{schema_version: 1, ok: false, error: message})))
    Map.get(args, :error_fun, fn text -> IO.puts(:stderr, text) end).("aiur: epic: " <> message)
    if kind == :usage, do: 64, else: 1
  end

  defp usage(message), do: {:usage, message}
end

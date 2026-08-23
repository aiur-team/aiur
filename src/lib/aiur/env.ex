defmodule Aiur.Env do
  @moduledoc """
  Runtime behaviour built on `Aiur.Env.Schema`: startup validation, the
  disabled-integrations boot notice, `.env.example` generation, and the
  `~/.aiur/.env` vs `./.env` precedence-conflict warning.

  ## Startup validation

  `validate_startup!/1` is the boot gate `Aiur.Application` calls (in
  non-test environments). It fails the boot, naming the variable and what was
  expected, when:

    * a value fails its declared type — e.g. `AIUR_OPENCODE_BRIDGE_PORT=banana`;
    * `AIUR_SUPERVISOR_TOKEN` is present but is not a usable bearer credential;
    * a credential group is partially configured (`GITHUB_APP_ID` without
      `GITHUB_APP_INSTALLATION_ID`, or one dashboard credential without the
      other);
    * no GitHub credential is configured (`GITHUB_TOKEN` absent and the GitHub
      App group not complete) — only when the active tracker is GitHub.

  Absence of an *optional* integration is never a failure: the schema encodes
  "feature off" defaults, and `warn_disabled_integrations/1` names what is off
  exactly once at startup.

  ## Never emit real values

  Rendering uses names, types and non-sensitive defaults only. Secret values
  render as an empty placeholder, precedence-conflict warnings name the
  variable but never its value, and no real value from any `.env` file ever
  reaches the generated example, logs, or error output.
  """

  require Logger

  alias Aiur.Env.Schema
  alias Aiur.Env.Types
  alias Aiur.Init.Dotenv
  alias Aiur.SupervisorToken

  @doc "Delegated: every declared env-var spec entry, `{name, spec}`."
  @spec specs() :: [{String.t(), Schema.spec()}]
  def specs, do: Schema.specs()

  @doc "Delegated: every declared env-var name."
  @spec names() :: [String.t()]
  def names, do: Schema.names()

  @doc "Delegated: the spec for `name`, or `nil`."
  @spec spec_for(String.t()) :: Schema.spec() | nil
  def spec_for(name), do: Schema.spec_for(name)

  @doc "Delegated: env-var names that are secrets."
  @spec secret_names() :: [String.t()]
  def secret_names, do: Schema.secret_names()

  @doc """
  Validates `env` (defaults to the process environment) for type errors,
  unusable configured credentials, and partial credential groups.
  Tracker-independent: the GitHub credential requirement is applied by
  `validate_startup!/1`.

  Returns `{:ok, :ok}` or `{:error, [message]}` where each message names the
  variable and what was expected.
  """
  @spec validate(map()) :: {:ok, :ok} | {:error, [String.t()]}
  def validate(env \\ System.get_env()) do
    errors = type_errors(env) ++ group_errors(env) ++ supervisor_token_errors(env)

    if errors == [], do: {:ok, :ok}, else: {:error, errors}
  end

  @doc """
  Boot gate. Raises with a message naming each offending variable when the
  environment is invalid, so a misconfiguration aborts the boot instead of
  failing at first use hours later.

  Options:

    * `:require_github_credential` (default `true`) — whether the GitHub
      credential requirement applies. `Aiur.Application` resolves this from
      the active tracker kind so a Linear or memory tracker does not demand
      GitHub credentials.

  The caller gates the whole call on a non-test environment.
  """
  @spec validate_startup!(map(), keyword()) :: :ok
  def validate_startup!(env \\ System.get_env(), opts \\ []) do
    require_github = Keyword.get(opts, :require_github_credential, true)

    errors =
      case validate(env) do
        {:ok, :ok} -> []
        {:error, errs} -> errs
      end

    errors = if require_github, do: errors ++ credential_errors(env), else: errors

    case errors do
      [] -> :ok
      _ -> raise ArgumentError, message: format_startup_errors(errors)
    end
  end

  @doc """
  Renders the checked-in `.env.example` from the schema: `##` group headers,
  one `#` purpose line above each key, and a terse right-hand fetch note
  aligned to a common column. Secret values render empty; no real value from
  any `.env` file is ever included.
  """
  @spec render_example() :: String.t()
  def render_example do
    header = render_header()
    sections = render_sections()

    Enum.join([header, sections], "\n")
  end

  @doc """
  Describes the optional integrations that are currently off, one string each,
  or `[]` when nothing is off. The strings are written (once) to the boot log
  by `warn_disabled_integrations/1`.
  """
  @spec disabled_integrations(map()) :: [String.t()]
  def disabled_integrations(env \\ System.get_env()) do
    [
      disabled_github_app(env),
      disabled_webhook(env),
      disabled_linear(env),
      disabled_voice(env),
      disabled_dashboard(env),
      disabled_decision_api(env),
      disabled_provider_keys(env)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Logs a single startup line naming the optional integrations that are off and
  why, or nothing when all are configured. Not a per-variable warning.
  """
  @spec warn_disabled_integrations(map()) :: :ok
  def warn_disabled_integrations(env \\ System.get_env()) do
    case disabled_integrations(env) do
      [] -> :ok
      disabled -> Logger.info("aiur_boot phase=env disabled_integrations=#{Enum.join(disabled, ", ")}")
    end

    :ok
  end

  @doc """
  Finds variables set to different values in both `home_env` and `repo_env`,
  returning `{name, home_value, repo_value}` tuples. `home_env` wins at
  runtime (the launcher loads it first and only fills unset names), so a
  returned conflict means the repo value is silently dead — the exact live bug
  this ticket reports.
  """
  @spec precedence_conflicts(Path.t(), Path.t()) :: [{String.t(), String.t(), String.t()}]
  def precedence_conflicts(home_env, repo_env) do
    home = read_dotenv(home_env)
    repo = read_dotenv(repo_env)

    home
    |> Enum.flat_map(fn {key, home_value} ->
      case Map.fetch(repo, key) do
        {:ok, repo_value} when repo_value != home_value -> [{key, home_value, repo_value}]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Human-readable warning lines for `precedence_conflicts/2` results. Each line
  names the variable but never its value, so a conflicting secret is not
  leaked to the log.
  """
  @spec precedence_warnings([{String.t(), String.t(), String.t()}], String.t(), String.t()) :: [String.t()]
  def precedence_warnings(conflicts, home_label \\ "~/.aiur/.env", repo_label \\ "./.env") do
    Enum.map(conflicts, fn {key, _home_value, _repo_value} ->
      "environment precedence conflict: #{key} is set to different values in " <>
        "#{home_label} and #{repo_label}; the #{home_label} value wins and the " <>
        "#{repo_label} value is ignored"
    end)
  end

  @doc """
  Emits the precedence-conflict warnings for the real `~/.aiur/.env` and
  `./.env` files as startup warnings. Non-fatal: it only ever reports silent
  shadowing, it never aborts the boot.
  """
  @spec warn_precedence_conflicts() :: :ok
  def warn_precedence_conflicts do
    home = Path.join(System.user_home!(), ".aiur/.env")
    repo = Path.join(File.cwd!(), ".env")

    Enum.each(precedence_warnings(precedence_conflicts(home, repo)), &Logger.warning/1)
    :ok
  end

  # --- validation ------------------------------------------------------------

  defp validated_specs, do: Enum.filter(specs(), fn {_name, spec} -> spec[:validate] end)

  defp type_errors(env) do
    Enum.flat_map(validated_specs(), fn {name, spec} -> type_error_for(env, name, spec) end)
  end

  defp type_error_for(env, name, spec) do
    case Map.get(env, name) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: [], else: type_error(name, spec, value)

      _ ->
        []
    end
  end

  defp type_error(name, spec, value) do
    case parse_value(spec[:type], value) do
      {:ok, _typed} -> []
      {:error, expected} -> ["#{name} must be #{expected}, got #{inspect(value)}"]
    end
  end

  defp parse_value(:string, value), do: {:ok, value}
  defp parse_value(:path, value), do: {:ok, value}
  defp parse_value(:secret, value), do: {:ok, value}
  defp parse_value(:integer, value), do: Types.integer(value)
  defp parse_value(:boolean, value), do: Types.boolean(value)

  defp group_errors(env) do
    Schema.credential_groups()
    |> Enum.sort_by(fn {id, _group} -> id end)
    |> Enum.flat_map(fn {_id, group} -> group_error(group, env) end)
  end

  defp group_error(group, env) do
    if Enum.any?(group.members, &set?(env, &1)) do
      case group_missing(group, env) do
        [] -> []
        missing -> [group.missing_message.(missing)]
      end
    else
      []
    end
  end

  defp group_missing(group, env) do
    in_one_of = group.one_of |> List.flatten() |> MapSet.new()

    plain_missing =
      group.members
      |> Enum.reject(&(MapSet.member?(in_one_of, &1) or set?(env, &1)))

    one_of_missing =
      for alternatives <- group.one_of, not Enum.any?(alternatives, &set?(env, &1)) do
        "one of #{Enum.join(alternatives, " / ")}"
      end

    plain_missing ++ one_of_missing
  end

  defp credential_errors(env) do
    requirement = Schema.github_credential_requirement()

    if set?(env, requirement.token) do
      []
    else
      group = Map.fetch!(Schema.credential_groups(), requirement.alternative_group)

      if group_complete?(group, env), do: [], else: [requirement.missing_message]
    end
  end

  defp supervisor_token_errors(env) do
    case SupervisorToken.classify(Map.get(env, "AIUR_SUPERVISOR_TOKEN")) do
      :invalid -> ["AIUR_SUPERVISOR_TOKEN must be a bearer-safe token of at least 32 bytes with no surrounding whitespace"]
      _missing_or_valid -> []
    end
  end

  defp group_complete?(group, env) do
    in_one_of = group.one_of |> List.flatten() |> MapSet.new()

    members_ok? =
      Enum.all?(group.members, fn member -> MapSet.member?(in_one_of, member) or set?(env, member) end)

    members_ok? and
      Enum.all?(group.one_of, fn alternatives -> Enum.any?(alternatives, &set?(env, &1)) end)
  end

  defp set?(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp format_startup_errors(errors) do
    "Invalid environment configuration at startup:\n" <>
      Enum.map_join(errors, "\n", &("  - " <> &1))
  end

  # --- disabled-integration notices ------------------------------------------

  defp disabled_github_app(env) do
    app = Map.fetch!(Schema.credential_groups(), :github_app)

    cond do
      set?(env, "GITHUB_TOKEN") and not group_complete?(app, env) ->
        "GitHub App auth off (using the GITHUB_TOKEN fallback)"

      not set?(env, "GITHUB_TOKEN") and group_complete?(app, env) ->
        "GITHUB_TOKEN fallback off (using GitHub App auth)"

      true ->
        nil
    end
  end

  defp disabled_webhook(env) do
    unless set?(env, "AIUR_GITHUB_WEBHOOK_SECRET"), do: "webhooks off (no secret; polling only)"
  end

  defp disabled_linear(env) do
    unless set?(env, "LINEAR_API_KEY"), do: "Linear tracker off (no LINEAR_API_KEY)"
  end

  defp disabled_voice(env) do
    unless set?(env, "ELEVENLABS_API_KEY"), do: "voice off (no ELEVENLABS_API_KEY)"
  end

  defp disabled_dashboard(env) do
    unless dashboard_configured?(env),
      do: "dashboard credentials off (no AIUR_DASHBOARD_USERNAME/PASSWORD; dashboard refuses all requests)"
  end

  defp disabled_decision_api(env) do
    case SupervisorToken.classify(Map.get(env, "AIUR_SUPERVISOR_TOKEN")) do
      :missing -> "Supervisor Decision API off (no AIUR_SUPERVISOR_TOKEN)"
      _configured -> nil
    end
  end

  defp disabled_provider_keys(env) do
    names = ["DEEPSEEK_API_KEY", "MOONSHOT_API_KEY", "OPENROUTER_API_KEY", "OPENROUTER_MANAGEMENT_KEY"]

    if Enum.any?(names, &set?(env, &1)),
      do: nil,
      else: "provider API keys off (no backend key configured)"
  end

  defp dashboard_configured?(env) do
    set?(env, "AIUR_DASHBOARD_USERNAME") and set?(env, "AIUR_DASHBOARD_PASSWORD")
  end

  # --- .env.example rendering -------------------------------------------------

  defp render_header do
    "# Aiur environment variables. Generated from the env schema — do not edit by hand; run `mix aiur.env.example`.\n"
  end

  defp render_sections do
    grouped = Enum.group_by(Schema.example_specs(), fn {_name, spec} -> spec[:group] end)
    content_column = content_column()

    sections =
      Schema.groups()
      |> Enum.flat_map(fn {group_id, header} ->
        case Map.get(grouped, group_id) do
          nil -> []
          specs -> [render_section(header, specs, content_column)]
        end
      end)

    Enum.join(sections, "\n\n")
  end

  defp render_section(nil, _specs, _content_column), do: ""

  defp render_section(header, specs, content_column) do
    body =
      Enum.map_join(specs, "\n", fn {name, spec} ->
        "# #{spec[:purpose]}\n" <> render_key_line(name, spec, content_column)
      end)

    "## #{header}\n#{body}"
  end

  defp render_key_line(name, spec, content_column) do
    value = example_value(spec)

    case spec[:fetch] do
      fetch when is_binary(fetch) ->
        String.pad_trailing("#{name}=#{value}", content_column) <> "# #{fetch}"

      _ ->
        "#{name}=#{value}"
    end
  end

  defp example_value(spec) do
    cond do
      secret?(spec) -> ""
      spec[:emit_default] and not is_nil(spec[:default]) -> to_string(spec[:default])
      true -> ""
    end
  end

  defp secret?(spec), do: spec[:type] == :secret or spec[:secret]

  # The common column at which right-hand fetch notes start: longest rendered
  # key/value line plus a little breathing room.
  defp content_column do
    longest =
      Schema.example_specs()
      |> Enum.map(fn {name, spec} -> String.length("#{name}=#{example_value(spec)}") end)
      |> Enum.max(fn -> 0 end)

    longest + 4
  end

  # --- precedence -------------------------------------------------------------

  defp read_dotenv(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> Dotenv.parse()
        |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put_new(acc, key, value) end)

      {:error, _} ->
        %{}
    end
  end
end

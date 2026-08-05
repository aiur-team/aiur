defmodule Aiur.GitHub.AppCredentials do
  @moduledoc """
  GitHub App static credentials for the daemon's installation-token
  authentication.

  The daemon replaces its `GITHUB_TOKEN` PAT with a short-lived GitHub App
  installation token (see `docs/security/daemon-token-posture.md` and #1375).
  The App's static credentials — app id, installation id, and the App private
  key — are loaded here from the environment (via `.env` at launch) and
  validated without ever logging the secret material.

  Credential environment variables:

    * `GITHUB_APP_ID` — the GitHub App numeric id (`iss` claim of the JWT).
    * `GITHUB_APP_INSTALLATION_ID` — the App installation id on the target
      org/repository, selected explicitly so a single App installed on several
      organizations authenticates against the intended one.
    * `GITHUB_APP_PRIVATE_KEY` — inline PEM of the App's private key.
    * `GITHUB_APP_PRIVATE_KEY_PATH` — path to the PEM file; preferred over the
      inline variable so the key never appears in the process environment or
      shell history.

  The private key path takes precedence over the inline value. A deployment
  that configures all three values is not "more secure" than one that
  configures the path alone — only one source is read.
  """

  @app_id_env "GITHUB_APP_ID"
  @installation_id_env "GITHUB_APP_INSTALLATION_ID"
  @private_key_env "GITHUB_APP_PRIVATE_KEY"
  @private_key_path_env "GITHUB_APP_PRIVATE_KEY_PATH"

  @type t :: %{
          app_id: String.t(),
          installation_id: String.t(),
          private_key: binary()
        }

  @doc "The `GITHUB_APP_ID` environment variable name."
  @spec app_id_env() :: String.t()
  def app_id_env, do: @app_id_env

  @doc "The `GITHUB_APP_INSTALLATION_ID` environment variable name."
  @spec installation_id_env() :: String.t()
  def installation_id_env, do: @installation_id_env

  @doc "The `GITHUB_APP_PRIVATE_KEY` environment variable name."
  @spec private_key_env() :: String.t()
  def private_key_env, do: @private_key_env

  @doc "The `GITHUB_APP_PRIVATE_KEY_PATH` environment variable name."
  @spec private_key_path_env() :: String.t()
  def private_key_path_env, do: @private_key_path_env

  @doc """
  True when all three App credentials (app id, installation id, private key)
  resolve from the environment. This gates whether the daemon authenticates
  with an installation token or falls back to the `GITHUB_TOKEN` PAT.

  Deliberately an environment-only check: it runs on every `Config.token/0`
  call — i.e. on every GitHub API request — so it must never touch the
  filesystem. A configured-but-unreadable key path is therefore "configured"
  here and fails closed later at acquisition time, where the failure is
  retried and raised as a needs-attention alert, rather than silently
  downgrading the daemon to the `GITHUB_TOKEN` PAT.
  """
  @spec configured?() :: boolean()
  def configured? do
    is_binary(app_id()) and is_binary(installation_id()) and private_key_configured?()
  end

  @doc """
  True when a private-key source (path or inline PEM) is present in the
  environment. Does not read or parse the key.
  """
  @spec private_key_configured?() :: boolean()
  def private_key_configured? do
    is_binary(env_value(@private_key_path_env)) or is_binary(env_value(@private_key_env))
  end

  @doc "The configured GitHub App id, or nil when unset/blank."
  @spec app_id() :: String.t() | nil
  def app_id, do: env_value(@app_id_env)

  @doc "The configured installation id, or nil when unset/blank."
  @spec installation_id() :: String.t() | nil
  def installation_id, do: env_value(@installation_id_env)

  @doc """
  The App private key PEM, preferring `GITHUB_APP_PRIVATE_KEY_PATH` over the
  inline `GITHUB_APP_PRIVATE_KEY`. Returns `{:ok, pem}` or an error tuple;
  never raises, never returns the key on an error path.
  """
  @spec private_key_pem() :: {:ok, binary()} | {:error, term()}
  def private_key_pem do
    case env_value(@private_key_path_env) do
      path when is_binary(path) ->
        case File.read(path) do
          {:ok, pem} -> normalize_pem(pem)
          {:error, reason} -> {:error, {:private_key_path_unreadable, path, reason}}
        end

      _ ->
        case env_value(@private_key_env) do
          pem when is_binary(pem) -> normalize_pem(pem)
          _ -> {:error, :missing_private_key}
        end
    end
  end

  @doc """
  Parses the configured private key into a `JOSE.JWK`. Returns
  `{:ok, jwk}` or `{:error, :missing_private_key | :invalid_private_key}`;
  never raises on malformed input.
  """
  @spec parse_private_key() :: {:ok, JOSE.JWK.t()} | {:error, term()}
  def parse_private_key do
    with {:ok, pem} <- private_key_pem() do
      jwk_from_pem(pem)
    end
  end

  @doc """
  Human-readable description of which credential is missing, for diagnostics.
  Never includes the key material.
  """
  @spec missing_credential() :: atom() | nil
  def missing_credential do
    cond do
      is_nil(app_id()) -> :missing_app_id
      is_nil(installation_id()) -> :missing_installation_id
      match?({:error, :missing_private_key}, private_key_pem()) -> :missing_private_key
      true -> nil
    end
  end

  @doc """
  Strips secret-adjacent detail (notably the private-key file path) from a
  credential error so it is safe to log. Callers that log an acquisition
  failure must pass the reason through here first.
  """
  @spec sanitize_error(term()) :: term()
  def sanitize_error({:private_key_path_unreadable, _path, reason}),
    do: {:private_key_path_unreadable, reason}

  def sanitize_error(reason), do: reason

  # Private-key PEM entry types. A public key or certificate PEM decodes
  # cleanly and `JOSE.JWK.from_pem/1` accepts it, but the resulting JWK cannot
  # sign — it would raise a FunctionClauseError deep inside JOSE at the first
  # JWT signature, breaking this module's never-raises contract. Reject it here.
  # GitHub Apps issue RSA keys and the App JWT is always RS256, so PKCS#1
  # (`RSAPrivateKey`) and PKCS#8 (`PrivateKeyInfo`) are the accepted forms.
  @private_key_pem_types [:RSAPrivateKey, :PrivateKeyInfo]

  defp jwk_from_pem(pem) do
    case :public_key.pem_decode(pem) do
      [{type, _der, _cipher} | _] when type in @private_key_pem_types ->
        signing_jwk(pem)

      _ ->
        {:error, :invalid_private_key}
    end
  end

  # Confirms the parsed key can actually produce a signature, so a structurally
  # private-looking but unusable PEM fails here as an error tuple rather than
  # raising later inside the refresher.
  defp signing_jwk(pem) do
    jwk = JOSE.JWK.from_pem(pem)
    _signature = JOSE.JWS.compact(JOSE.JWT.sign(jwk, %{"alg" => "RS256", "typ" => "JWT"}, %{}))
    {:ok, jwk}
  rescue
    _ -> {:error, :invalid_private_key}
  catch
    _, _ -> {:error, :invalid_private_key}
  end

  defp normalize_pem(pem) do
    case String.trim(pem) do
      "" -> {:error, :missing_private_key}
      trimmed -> {:ok, trimmed}
    end
  end

  defp env_value(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end

defmodule AiurWeb.DashboardAuth.Passkeys do
  @moduledoc false

  alias Aiur.Config
  alias Aiur.Config.Paths
  alias AiurWeb.DashboardAuth.ChallengeStore

  @file_name "dashboard-passkeys.json"

  @spec enabled?() :: boolean()
  def enabled?, do: Config.settings!().dashboard_auth.passkeys
  @spec available?() :: boolean()
  def available?, do: enabled?() and match?({:ok, [_ | _]}, credentials())

  @spec origin_and_rp_id() :: {:ok, String.t(), String.t()} | {:error, :public_https_url_required}
  def origin_and_rp_id do
    with url when is_binary(url) <- Config.settings!().server.public_url,
         %URI{scheme: "https", host: host} = uri <- URI.parse(url) do
      origin = "https://#{host}" <> if(uri.port && uri.port != 443, do: ":#{uri.port}", else: "")
      {:ok, origin, host}
    else
      _ -> {:error, :public_https_url_required}
    end
  end

  @spec registration_challenge() :: {:ok, Wax.Challenge.t()} | {:error, atom()}
  def registration_challenge do
    with true <- enabled?(),
         {:ok, origin, host} <- origin_and_rp_id() do
      {:ok, Wax.new_registration_challenge(attestation: "none", origin: origin, rp_id: host, user_verification: "required")}
    else
      _ -> {:error, :passkeys_unavailable}
    end
  end

  @spec authentication_challenge() :: {:ok, Wax.Challenge.t(), list()} | {:error, atom()}
  def authentication_challenge do
    with true <- enabled?(),
         {:ok, origin, host} <- origin_and_rp_id(),
         {:ok, credentials} <- credentials() do
      if credentials == [] do
        {:error, :no_passkeys}
      else
        wax_credentials = Enum.map(credentials, &{&1.id, &1.key})
        {:ok, Wax.new_authentication_challenge(allow_credentials: wax_credentials, origin: origin, rp_id: host, user_verification: "required"), credentials}
      end
    else
      _ -> {:error, :passkeys_unavailable}
    end
  end

  @spec put_challenge(Wax.Challenge.t(), term()) :: {:ok, String.t()} | {:error, :capacity_exceeded}
  def put_challenge(challenge, owner), do: ChallengeStore.put(challenge, ChallengeStore, owner)
  @spec take_challenge(term()) :: {:ok, Wax.Challenge.t()} | {:error, atom()}
  def take_challenge(id) when is_binary(id), do: ChallengeStore.take(id)
  def take_challenge(_), do: {:error, :challenge_missing_or_replayed}

  @spec register(Wax.Challenge.t(), binary(), binary(), term(), String.t()) :: :ok | {:error, atom()}
  def register(challenge, attestation, client_data_json, label, owner_email) do
    with_credential_lock(fn -> do_register(challenge, attestation, client_data_json, label, owner_email) end)
  end

  defp do_register(challenge, attestation, client_data_json, label, owner_email) do
    with %Wax.Challenge{} <- challenge,
         {:ok, attestation} <- decode64(attestation),
         {:ok, client_data_json} <- decode64(client_data_json),
         {:ok, {auth_data, _attestation}} <- Wax.register(attestation, client_data_json, challenge),
         credential <- auth_data.attested_credential_data,
         id <- Base.url_encode64(credential.credential_id, padding: false),
         {:ok, existing} <- credentials(),
         false <- Enum.any?(existing, &(&1.id == id)),
         key <- credential.credential_public_key,
         :ok <- store_credentials(existing ++ [%{id: id, key: key, sign_count: auth_data.sign_count, label: safe_label(label), email: String.downcase(owner_email)}]) do
      :ok
    else
      _ -> {:error, :invalid_registration}
    end
  end

  @spec authenticate(Wax.Challenge.t(), map()) :: {:ok, map()} | {:error, atom()}
  def authenticate(challenge, assertion) when is_map(assertion) do
    with %Wax.Challenge{} <- challenge,
         {:ok, id_raw} <- decode64(assertion["rawId"] || assertion["id"]),
         id <- Base.url_encode64(id_raw, padding: false),
         {:ok, credentials} <- credentials(),
         credential when not is_nil(credential) <- Enum.find(credentials, &(&1.id == id)),
         response when is_map(response) <- assertion["response"],
         {:ok, client_data_json} <- decode64(response["clientDataJSON"]),
         {:ok, auth_data_bin} <- decode64(response["authenticatorData"]),
         {:ok, signature} <- decode64(response["signature"]),
         {:ok, auth_data} <- Wax.authenticate(id, auth_data_bin, signature, client_data_json, challenge),
         true <- sign_count_valid?(credential.sign_count, auth_data.sign_count),
         :ok <- update_sign_count(credential, auth_data.sign_count) do
      {:ok, credential}
    else
      _ -> {:error, :invalid_assertion}
    end
  end

  def authenticate(_challenge, _assertion), do: {:error, :invalid_assertion}

  @spec allowed_user?(map()) :: boolean()
  def allowed_user?(%{email: email}) do
    allowed = Config.settings!().dashboard_auth.google.allowed_emails
    is_binary(email) and String.downcase(email) in Enum.map(allowed, &String.downcase/1)
  end

  @doc false
  @spec sign_count_valid?(non_neg_integer(), non_neg_integer()) :: boolean()
  def sign_count_valid?(0, 0), do: true
  def sign_count_valid?(previous, current), do: current > previous

  defp update_sign_count(old, count) do
    with_credential_lock(fn -> update_sign_count_locked(old, count) end)
  end

  defp update_sign_count_locked(old, count) do
    case credentials() do
      {:ok, current} -> persist_sign_count(current, old.id, count)
      {:error, _reason} -> {:error, :credential_store_unavailable}
    end
  end

  defp persist_sign_count(current, id, count) do
    case Enum.find(current, &(&1.id == id)) do
      %{sign_count: previous} when (previous == 0 and count == 0) or count > previous ->
        updated = Enum.map(current, &set_sign_count(&1, id, count))
        store_credentials(updated)

      _ ->
        {:error, :credential_store_unavailable}
    end
  end

  defp set_sign_count(%{id: id} = credential, id, count), do: %{credential | sign_count: count}
  defp set_sign_count(credential, _id, _count), do: credential

  defp credentials, do: with({:ok, path} <- file_path(), do: read_credentials(path))

  defp with_credential_lock(fun) do
    case :global.trans({{__MODULE__, :credential_file}, self()}, fun) do
      {:aborted, _reason} -> {:error, :credential_store_unavailable}
      result -> result
    end
  end

  defp read_credentials(path) do
    case File.read(path) do
      {:ok, json} ->
        with {:ok, records} when is_list(records) <- Jason.decode(json), do: {:ok, Enum.map(records, &decode_record/1)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_credentials_file}
  end

  defp store_credentials(records) do
    with {:ok, path} <- file_path(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- Aiur.Fs.atomic_write(path, Jason.encode!(Enum.map(records, &encode_record/1)), mode: 0o600, fsync: true),
         do: File.chmod(path, 0o600)
  end

  defp file_path do
    case Application.get_env(:aiur, :dashboard_passkeys_path) do
      path when is_binary(path) ->
        {:ok, path}

      _ ->
        case Paths.decision_state_dir() do
          {:ok, directory} -> {:ok, Path.join(directory, @file_name)}
          error -> error
        end
    end
  end

  defp encode_record(%{id: id, key: key, sign_count: count, label: label, email: email}) do
    %{id: id, key: Map.new(key, fn {k, v} -> {to_string(k), encode_key_value(v)} end), sign_count: count, label: label, email: email}
  end

  defp decode_record(%{"id" => id, "key" => key, "sign_count" => count, "label" => label, "email" => email}) do
    decoded_key = Map.new(key, fn {k, v} -> {String.to_integer(k), decode_key_value(v)} end)
    %{id: id, key: decoded_key, sign_count: count, label: label, email: email}
  end

  defp encode_key_value(value) when is_binary(value), do: %{"binary" => Base.encode64(value)}
  defp encode_key_value(value), do: value
  defp decode_key_value(%{"binary" => value}), do: Base.decode64!(value)
  defp decode_key_value(value), do: value

  defp decode64(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode64(_), do: :error
  defp safe_label(label) when is_binary(label), do: label |> String.trim() |> String.slice(0, 80)
  defp safe_label(_), do: "Passkey"
end

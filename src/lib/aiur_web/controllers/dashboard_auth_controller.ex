defmodule AiurWeb.DashboardAuthController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  alias Aiur.Config
  alias AiurWeb.DashboardAuth.Passkeys
  alias AiurWeb.FinancialDataAccess
  alias Assent.Strategy.Google

  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, _params) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    links = if google_enabled?(), do: ~s(<a href="/auth/google">Sign in with Google</a>), else: ""
    passkey_button = if Passkeys.available?(), do: ~s(<button id="passkey-login" type="button">Sign in with a passkey</button>), else: ""
    register_button = if Passkeys.enabled?() and fresh_google_session?(Plug.Conn.get_session(conn)), do: ~s(<button id="passkey-register" type="button">Register a passkey</button>), else: ""
    logout = ~s(<form method="post" action="/auth/logout"><input type="hidden" name="_csrf_token" value="#{csrf}"><button type="submit">Sign out</button></form>)
    javascript = passkey_javascript(csrf)

    html(
      conn,
      ~s|<!doctype html><html><head><meta charset="utf-8"><meta name="csrf-token" content="#{csrf}"><title>Sign in to Aiur</title></head><body><section><h1>Sign in to Aiur</h1>#{links}#{passkey_button}#{register_button}#{logout}<p id="auth-error" role="alert"></p></section><script>#{javascript}</script></body></html>|
    )
  end

  @spec google(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google(conn, _params) do
    with true <- google_enabled?(),
         {:ok, %{url: url, session_params: session_params}} <- Google.authorize_url(google_config()) do
      conn
      |> put_session(:google_session_params, session_params)
      |> put_resp_header("cache-control", "no-store")
      |> redirect(external: url)
    else
      _ -> conn |> put_status(:service_unavailable) |> text("Google sign-in is not configured")
    end
  end

  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, params) do
    session_params = get_session(conn, :google_session_params)

    with true <- is_map(session_params),
         {:ok, %{user: user}} <- Google.callback(Keyword.put(google_config(), :session_params, session_params), params) do
      complete_google_sign_in(conn, user)
    else
      _ -> google_sign_in_failed(conn)
    end
  end

  @doc false
  @spec complete_google_sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def complete_google_sign_in(conn, user) do
    with true <- allowed_google_user?(user, Config.settings!().dashboard_auth.google.allowed_emails),
         {:ok, marker} <- FinancialDataAccess.new_browser_session_marker() do
      conn
      |> configure_session(renew: true)
      |> delete_session(:google_session_params)
      |> put_session(FinancialDataAccess.session_key(), marker)
      |> put_session(:google_authenticated_at, System.system_time(:second))
      |> put_session(:google_email, user["email"])
      |> put_resp_header("cache-control", "no-store")
      |> redirect(to: if(Passkeys.enabled?(), do: "/auth/login", else: "/"))
    else
      _ -> google_sign_in_failed(conn)
    end
  end

  defp google_sign_in_failed(conn) do
    conn
    |> clear_session()
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:unauthorized)
    |> text("Google sign-in failed. Return to /auth/login and try again.")
  end

  @spec logout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def logout(conn, _params) do
    if match?({:ok, _context}, FinancialDataAccess.context_from_session(get_session(conn))) do
      :ok = FinancialDataAccess.Generation.invalidate()
    end

    conn
    |> clear_session()
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: "/auth/login")
  end

  @spec authentication_challenge(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authentication_challenge(conn, _params) do
    with {:ok, challenge, credentials} <- Passkeys.authentication_challenge(),
         {:ok, challenge_id} <- Passkeys.put_challenge(challenge, conn.remote_ip) do
      conn
      |> put_session(:passkey_authentication_challenge, challenge_id)
      |> json(%{challenge: b64(challenge.bytes), rp_id: challenge.rp_id, allow_credentials: Enum.map(credentials, &%{id: &1.id, type: "public-key"})})
    else
      _ -> conn |> put_status(:service_unavailable) |> json(%{error: "passkeys unavailable"})
    end
  end

  @spec authentication_finish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authentication_finish(conn, %{"assertion" => assertion}) when is_map(assertion) do
    challenge_id = get_session(conn, :passkey_authentication_challenge)

    with {:ok, challenge} <- Passkeys.take_challenge(challenge_id),
         {:ok, credential} <- Passkeys.authenticate(challenge, assertion),
         true <- Passkeys.allowed_user?(credential),
         {:ok, marker} <- FinancialDataAccess.new_browser_session_marker() do
      conn
      |> configure_session(renew: true)
      |> delete_session(:passkey_authentication_challenge)
      |> put_session(FinancialDataAccess.session_key(), marker)
      |> put_session(:passkey_authenticated_at, System.system_time(:second))
      |> put_resp_header("cache-control", "no-store")
      |> json(%{ok: true, label: credential.label})
    else
      _ -> conn |> delete_session(:passkey_authentication_challenge) |> put_status(:unauthorized) |> json(%{error: "passkey authentication failed"})
    end
  end

  def authentication_finish(conn, _params), do: conn |> put_status(:bad_request) |> json(%{error: "invalid assertion"})

  @spec registration_challenge(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def registration_challenge(conn, _params) do
    session = Plug.Conn.get_session(conn)

    with true <- Passkeys.enabled?() and fresh_google_session?(session),
         {:ok, challenge} <- Passkeys.registration_challenge(),
         {:ok, challenge_id} <- Passkeys.put_challenge(challenge, conn.remote_ip) do
      conn
      |> put_session(:passkey_registration_challenge, challenge_id)
      |> json(%{
        challenge: b64(challenge.bytes),
        rp_id: challenge.rp_id,
        user: %{id: b64(:crypto.hash(:sha256, System.get_env("AIUR_GOOGLE_CLIENT_ID") || "aiur")), name: "operator", displayName: "Aiur operator"}
      })
    else
      _ -> conn |> put_status(:forbidden) |> json(%{error: "fresh Google sign-in required"})
    end
  end

  @spec registration_finish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def registration_finish(conn, %{"credential" => credential} = params) when is_map(credential) do
    session = Plug.Conn.get_session(conn)
    challenge_id = get_session(conn, :passkey_registration_challenge)
    response = if is_map(credential["response"]), do: credential["response"], else: %{}
    label = params["label"] || "Passkey"

    with true <- fresh_google_session?(session),
         {:ok, challenge} <- Passkeys.take_challenge(challenge_id),
         email when is_binary(email) <- session[:google_email] || session["google_email"],
         :ok <- Passkeys.register(challenge, response["attestationObject"], response["clientDataJSON"], label, email) do
      conn |> delete_session(:passkey_registration_challenge) |> json(%{ok: true})
    else
      _ -> conn |> delete_session(:passkey_registration_challenge) |> put_status(:unprocessable_entity) |> json(%{error: "passkey registration failed"})
    end
  end

  def registration_finish(conn, _params), do: conn |> put_status(:bad_request) |> json(%{error: "invalid credential"})

  defp google_config do
    public_url = Config.settings!().server.public_url

    [
      client_id: System.get_env("AIUR_GOOGLE_CLIENT_ID"),
      client_secret: System.get_env("AIUR_GOOGLE_CLIENT_SECRET"),
      redirect_uri: String.trim_trailing(public_url || "", "/") <> "/auth/google/callback",
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      authorization_params: [scope: "openid email", prompt: "select_account"]
    ]
  end

  defp google_enabled? do
    settings = Config.settings!()
    url = settings.server.public_url
    emails = settings.dashboard_auth.google.allowed_emails

    is_binary(url) and URI.parse(url).scheme == "https" and is_list(emails) and emails != [] and
      present?(System.get_env("AIUR_GOOGLE_CLIENT_ID")) and present?(System.get_env("AIUR_GOOGLE_CLIENT_SECRET"))
  rescue
    _ -> false
  end

  @doc false
  @spec allowed_google_user?(map(), list()) :: boolean()
  def allowed_google_user?(user, allowed) when is_map(user) and is_list(allowed) do
    email = user["email"]
    verified = user["email_verified"]

    verified == true and is_binary(email) and Enum.any?(allowed, &(is_binary(&1) and String.downcase(email) == String.downcase(&1)))
  end

  def allowed_google_user?(_, _), do: false

  defp fresh_google_session?(session) do
    timestamp = session[:google_authenticated_at] || session["google_authenticated_at"]

    is_integer(timestamp) and System.system_time(:second) - timestamp <= 300 and
      match?({:ok, _}, FinancialDataAccess.context_from_session(session))
  end

  defp b64(value), do: Base.url_encode64(value, padding: false)

  defp passkey_javascript(csrf) do
    """
    const csrf=#{Jason.encode!(csrf)};
    const dec=s=>Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
    const enc=b=>btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
    const post=async(url,body={})=>fetch(url,{method:'POST',headers:{'content-type':'application/json','x-csrf-token':csrf},body:JSON.stringify(body)});
    const btn=document.getElementById('passkey-login');
    if(btn) btn.onclick=async()=>{try{const c=await (await post('/auth/passkeys/authentication/challenge')).json();c.challenge=dec(c.challenge);c.allow_credentials=c.allow_credentials.map(x=>({type:x.type,id:dec(x.id)}));const a=await navigator.credentials.get({publicKey:{challenge:c.challenge,rpId:c.rp_id,allowCredentials:c.allow_credentials,userVerification:'required'}});const r=a.response;const result=await post('/auth/passkeys/authentication/finish',{assertion:{id:enc(a.rawId),rawId:enc(a.rawId),response:{authenticatorData:enc(r.authenticatorData),clientDataJSON:enc(r.clientDataJSON),signature:enc(r.signature)}}});if(!result.ok)throw Error('Passkey sign-in failed');location.assign('/')}catch(e){document.getElementById('auth-error').textContent=e.message}};
    const reg=document.getElementById('passkey-register');
    if(reg) reg.onclick=async()=>{try{const c=await (await post('/auth/passkeys/registration/challenge')).json();c.challenge=dec(c.challenge);c.user.id=dec(c.user.id);const a=await navigator.credentials.create({publicKey:{challenge:c.challenge,rp:{id:c.rp_id,name:'Aiur'},user:c.user,pubKeyCredParams:[{type:'public-key',alg:-7},{type:'public-key',alg:-257}],authenticatorSelection:{userVerification:'required',residentKey:'preferred'},attestation:'none'}});const r=a.response;const result=await post('/auth/passkeys/registration/finish',{credential:{id:enc(a.rawId),rawId:enc(a.rawId),response:{attestationObject:enc(r.attestationObject),clientDataJSON:enc(r.clientDataJSON)}}});if(!result.ok)throw Error('Passkey registration failed');document.getElementById('auth-error').textContent='Passkey registered'}catch(e){document.getElementById('auth-error').textContent=e.message}};
    """
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end

# Railway deployments

Aiur has two hosted deployment kinds. Set `instance.mode: hosted` and choose
`instance.deployment_kind` to match who owns the credentials and provider bill.
Do not combine operator subscription credentials with a consumer service.

## Operator instance

An operator instance runs the operator's own tickets. Set:

```yaml
instance:
  mode: hosted
  deployment_kind: operator
```

For Claude Code, add `CLAUDE_CODE_OAUTH_TOKEN` as a Railway secret. Create the
long-lived value with `claude setup-token` on a trusted machine and paste it
into the service's secret settings. Aiur passes it only to Claude workers; it
does not require a browser login when the container starts.

For Codex subscription auth, attach a persistent Railway volume at the
`AIUR_BG_STATE_DIR` path (default `/root/.config/aiur`). On first setup, open a
platform shell or run `docker exec -it <container> sh`, then run:

```sh
CODEX_HOME="$AIUR_BG_STATE_DIR/codex" codex login --device-auth
```

Complete the device flow in a browser on your own machine. The resulting
`auth.json` stays under the state volume and is reused after container restarts;
Aiur does not open a browser during boot. Keep the volume private because it
contains the operator's subscription session. Alternatively configure
`OPENAI_API_KEY` for Codex API billing.

## Consumer instance

A consumer instance serves other users' jobs. Set:

```yaml
instance:
  mode: hosted
  deployment_kind: consumer
```

Configure API keys for every routed backend, such as `ANTHROPIC_API_KEY` for
Claude or `OPENAI_API_KEY` for Codex.

Do not set `CLAUDE_CODE_OAUTH_TOKEN` or mount a Codex subscription login.
Startup rejects the Claude subscription variable and reports the variable
needed when a configured backend has no usable API key. Consumer requests must
use API-key profiles; see #5700 for the per-job profile controls.

## Provider rejects a credential

If a provider returns HTTP 401, Aiur raises one dashboard attention and pauses
dispatch to that backend. Other configured backends can continue. Replace or
rotate the provider credential in Railway and restart the service; startup
clears the hold after it observes the changed credential.

For either deployment, persist `AIUR_BG_STATE_DIR` across releases. Startup
checks hosted credentials and names missing environment variables without
printing credential values.

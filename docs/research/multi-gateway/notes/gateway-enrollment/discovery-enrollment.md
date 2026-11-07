# Peer discovery and secure enrollment for a small self-hosted gateway cluster

Scope: one gateway daemon per machine, each with an HTTPS control API. Goals: (1) auto-discover peers on a shared tailnet, (2) manual registration with endpoint + credential on any network, (3) discovery never grants control. Sources fetched 2026-11-06; Tailscale Go docs were at module v1.104.5.

## Tailscale: what identity a daemon gets for an incoming request

### Takeaway
On a tailnet, a daemon can get a strong, unforgeable peer identity for every inbound connection: the source tailnet IP maps through LocalAPI `WhoIs` to a node, a user profile and a capability map. The cleanest authorization hook is a custom app capability, granted in the tailnet policy and read through `CapMap`. That identity is lost for Funnel (public) traffic, and a tagged node has no user identity, only its tags.

### Cited Findings
- tsnet embeds a tailnet node in a Go program. `Server` fields include `Hostname`, `Dir` (state; each server needs its own), `AuthKey` (wins over `TS_AUTHKEY`), `Ephemeral`, `AdvertiseTags` (the control server may refuse a tag) and `Store`. Methods include `Listen` (tailnet only), `ListenTLS`, `ListenFunnel`, `LocalClient`, `CertDomains` and `Up`. — [pkg.go.dev tsnet](https://pkg.go.dev/tailscale.com/tsnet)
- tsnet: "Use the WhoIs method on the client returned by Server.LocalClient to identify who is making a request." — [pkg.go.dev tsnet](https://pkg.go.dev/tailscale.com/tsnet)
- tsnet auth key order: `AuthKey`, `TS_AUTHKEY`, `TS_AUTH_KEY`, an OAuth client secret, workload identity federation, then an interactive login URL. Once the node is enrolled, stored state wins and the auth key is ignored unless `TSNET_FORCE_LOGIN=1` is set. — [pkg.go.dev tsnet](https://pkg.go.dev/tailscale.com/tsnet)
- `ListenFunnel` "announces on the public internet using Tailscale Funnel" and by default "also … listens on your local tailnet, so connections can come from either inside or outside your network". A `FunnelOnly` option restricts it to public traffic. — [pkg.go.dev tsnet](https://pkg.go.dev/tailscale.com/tsnet)
- LocalAPI client methods: `WhoIs(ctx, remoteAddr)`, `WhoIsForIP`, `WhoIsForService`, `WhoIsNodeKey`, `WhoIsProto`. `ErrPeerNotFound` is returned when no peer matches. — [pkg.go.dev tailscale.com/client/local](https://pkg.go.dev/tailscale.com/client/local)
- `WhoIsResponse{ Node *tailcfg.Node; UserProfile *tailcfg.UserProfile; CapMap tailcfg.PeerCapMap }`. "In successful whois responses, Node and UserProfile are never nil." — [pkg.go.dev apitype](https://pkg.go.dev/tailscale.com/client/tailscale/apitype)
- App capabilities go in a grant's `app` field. Names are `{domain}/{path}` (for example `example.com/cap/custom-app`), and the values are arrays of JSON objects. `tailscale.com` and `tailscale.io` are reserved, so an application should use a domain it controls. Apps read the capabilities through `tailscale whois` (debugging), LocalAPI (code), the Serve app-capabilities header, or tsnet. Example: `{"src":["group:developers"],"dst":["tag:app-servers"],"app":{"tailscale.com/cap/secrets":[{"action":["get","info"],"secret":["dev/*"]}]}}`. — [Tailscale KB: grants app capabilities](https://tailscale.com/kb/1537/grants-app-capabilities)
- Tags: "Applying a tag to a device removes any user-based authentication." A tagged device's identity is "the combination of all its tags (not the intersection)". Only tag owners (`tagOwners`) or admins can apply tags. Tags can be pre-assigned to auth keys. "The tagged device's key expiry is disabled by default." — [Tailscale KB: tags](https://tailscale.com/kb/1068/tags)
- Serve adds `Tailscale-User-Login`, `Tailscale-User-Name` and `Tailscale-User-Profile-Pic` for the backend. "These identity headers are not populated for traffic originating from tagged devices." Funnel traffic "does not include identity headers". Shared-device (external user) traffic counts as tailnet traffic, so it gets headers. — [Tailscale KB: Serve](https://tailscale.com/kb/1312/serve)
- Serve (v1.92+) forwards `Tailscale-App-Capabilities` only with `--accept-app-caps` and only for a caller granted one of the named capabilities. It is not sent for Funnel. Serve strips incoming copies of these headers "to avoid header spoofing". The backend should listen only on localhost, because otherwise a direct caller "could trivially provide their own values for these HTTP headers." — [Tailscale KB: Serve](https://tailscale.com/kb/1312/serve)
- Funnel listens only on ports 443, 8443 and 10000. It needs MagicDNS, HTTPS certificates and the `funnel` nodeAttr. It works only with `*.ts.net` names, and its bandwidth limits cannot be configured. Relays cannot decrypt the traffic; TLS terminates on the device. A port serves either Serve or Funnel, never both at once. Repeated certificate requests can hit Let's Encrypt rate limits. — [Tailscale KB: Funnel](https://tailscale.com/kb/1223/funnel)

### Inferences
- Peer-to-peer gateway calls should use **tagged nodes** (for example `tag:gateway`). WhoIs then yields `Node.Tags` and `CapMap`, not a user. Authorize with a custom capability such as `<owned-domain>/cap/gateway` with `{"role":["peer"]}` granted `tag:gateway -> tag:gateway`, not with the tag string alone. Revocation is then a policy edit, with no change on the daemon.
- Discovery on a tailnet (the peer list from LocalAPI status, or MagicDNS names) only tells the daemon a node exists. An enrollment rule is still needed: only peers whose WhoIs `CapMap` holds the gateway capability are eligible, and the daemon should still record and pin the peer (node key / stable node ID) at registration.
- Tagged nodes have key expiry off by default, so long-lived gateway nodes won't expire silently. The side effect is that node-key expiry gives no revocation. Revocation must come from removing the node, the tag or the grant.
- Never expose the control API on a Funnel listener. If tsnet `ListenFunnel` is used for anything, set `FunnelOnly` on a separate listener and treat every request on it as anonymous.
- If the daemon sits behind `tailscale serve` instead of tsnet, it must bind to localhost only, or the identity headers can be forged.

### Gaps
- I did not fetch the MagicDNS KB page. Its details (naming, `<tailnet>.ts.net` FQDN, search domains) are not verified here.
- The semantics of `WhoIsForService` (Tailscale Services / VIP services) were not documented on the fetched page.
- I did not confirm whether the LocalAPI `CapMap` for a peer holds only capabilities granted *to the receiving node* as dst. The KB implies it, but no exact wording was retrieved.

## mDNS/DNS-SD for LAN discovery

### Takeaway
mDNS is unauthenticated and link-local by design: any host on the link can claim a name or answer a query. Treat it only as a hint about where a peer might be. Trust must come from a separate, cryptographic enrollment step.

### Cited Findings
- `.local.` names are "meaningful only on the link where they originate". Any host may claim a name not already in use, after probing. — [RFC 6762 §3, §8](https://www.rfc-editor.org/rfc/rfc6762.html)
- The conflict-resolution algorithm "assumes cooperating participants". With antagonistic hosts on the link, participants "need to use IPsec signatures and/or DNSSEC signatures" to tell trusted messages from untrusted ones. "A malicious host could masquerade as" another name through an mDNS answer. — [RFC 6762 §21](https://www.rfc-editor.org/rfc/rfc6762.html)
- Port 5353 needs no privilege, even where ports below 1024 do. — [RFC 6762 §21](https://www.rfc-editor.org/rfc/rfc6762.html)
- Syncthing's own LAN discovery broadcasts the device ID and port every 30 seconds. "An eavesdropper on the local network can deduce which machines are running Syncthing." — [Syncthing security](https://docs.syncthing.net/users/security.html)

### Inferences
- An mDNS/DNS-SD record (for example `_aiur-gateway._tcp`) may carry an endpoint and a key fingerprint hint, but a client must check the fingerprint against an enrolled pin, never accept it from the record. Advertising also leaks presence, so make it opt-in.
- mDNS does not cross subnets or VPNs, so on a tailnet the tailnet peer list is the better discovery source.

### Gaps
- I did not retrieve the RFC 6763 (DNS-SD) security section or the RFC 6762 §11 source-address/TTL rules (the page fetch was truncated).

## How existing tools enroll peers

### Takeaway
Mature tools split three things: *transport identity* (a cert or key fingerprint), *admission* (an explicit accept, or a join secret pinned to the cluster CA) and *authorization* (ACL tokens or policies). Shared group secrets (gossip keys, k3s server tokens) are the weak point. They are effectively admin credentials and are expensive to rotate.

### Cited Findings
- **Syncthing:** the Device ID is a SHA-256 hash of the device certificate. Fingerprints are "compared to a preset list" at connect time. "Anyone who can access the Syncthing TLS keys and config file on your device can impersonate your device." Relays learn device IDs but cannot read data. — [Syncthing security](https://docs.syncthing.net/users/security.html)
- **Syncthing introducer:** devices are auto-added from an introducer's list (device IDs, labels and addresses only). A manually removed device "will be automatically re-added as long as the introducer device is still marked as such". Introducer status passes along (your introducer's introducer becomes yours). Two devices should never introduce each other. — [Syncthing introducer](https://docs.syncthing.net/users/introducer.html)
- **Syncthing per-device controls:** `remoteIgnoredDevice` (attempts are logged, never shown in the GUI), `autoAcceptFolders`, `untrusted` ("disallows ever sharing any unencrypted data with it") and `allowedNetwork` ("restricts connections to this device to only this network"). — [Syncthing config](https://docs.syncthing.net/users/config.html)
- **k3s secure token** = `K10` + cluster CA hash + `::` + credentials. It "enables the client to authenticate the identity of the cluster it is joining, before sending credentials". The joiner fetches the CA bundle without verification, hashes it, compares it to the token, then verifies the server certificate. A short token (no hash) "implicitly trusts the CA bundle presented by the server", which is open to MITM. — [k3s token docs](https://docs.k3s.io/cli/token)
- **k3s:** "Anyone with access to the server token essentially has full administrator access to the cluster." The agent token is static and "does not expire". Bootstrap tokens (`k3s token create --ttl`, default 24 h, format `[a-z0-9]{6}.[a-z0-9]{16}`) expire. `k3s token rotate` requires every server and agent that joined with the old token to restart with the new one. — [k3s token docs](https://docs.k3s.io/cli/token)
- **Nomad ACL:** `nomad acl bootstrap` creates one initial management token, and default-deny takes effect at once. Bootstrap "cannot be performed again unless the reset procedure is complete". The reset needs an `acl-bootstrap-reset` file holding the current reset index in the leader's data directory. — [Nomad ACL bootstrap](https://developer.hashicorp.com/nomad/docs/secure/acl/bootstrap)
- **Nomad mTLS:** use a private CA from `nomad tls ca create` ("should be a _private_ CA and not a public one like Let's Encrypt"). Certificates encode role and region (`server.<region>.nomad`, `client.<region>.nomad`), not hostnames. `verify_server_hostname` checks role and region, which stops other services signed by the same CA from posing as agents. `verify_https_client` requires client certificates on the HTTP API. Certificates reload on SIGHUP. — [Nomad TLS](https://developer.hashicorp.com/nomad/docs/secure/traffic/tls)
- **Consul gossip:** a shared symmetric key (`consul keygen`, 32 bytes base64) set in `encrypt`. Rollout to a live cluster is staged with `encrypt_verify_incoming/outgoing`, and every agent must be restarted (reload is not enough). Rotation runs `keyring -install` → `-list` → `-use` → `-remove`. "Unused keys in the keyring are a potential security risk." The gossip page does not cover authorization; it points to ACLs and mTLS as separate layers. — [Consul gossip encryption](https://developer.hashicorp.com/consul/docs/secure/encryption/gossip/enable)
- **SPAKE2 (PAKE):** lets two parties "derive a strong shared key without disclosing the password". Its two rounds include key confirmation by MACs over the transcript ("A MUST NOT consider the protocol complete until it receives and verifies cB"). It is not augmented, so the server stores a password equivalent; RFC points to OPAQUE for augmented use. SPAKE2 was not selected in the CFRG PAKE competition. — [RFC 9382](https://www.rfc-editor.org/rfc/rfc9382.html)

### Inferences
- A good fit for 2–10 gateways is **Syncthing-style identity** (each gateway has a self-generated key pair, and its ID is the SPKI/cert SHA-256) plus **k3s-style join strings** that carry the target's fingerprint, so the joiner verifies before sending a secret. Example: `aiur-join://host:port#sha256=<pin>&t=<one-time secret, TTL>`.
- Use explicit accept for unknown inbound peers, as Syncthing's pending-device prompt does. Do not build a transitive "introducer": the Syncthing docs show it re-adds removed devices and spreads trust down the chain.
- A pairing code (a short secret over SPAKE2, or a TOFU fingerprint compared by eye on both screens) suits interactive LAN pairing. A one-time token pinned to a fingerprint is simpler and enough when the operator copies a string between machines.
- Avoid a cluster-wide shared secret like a gossip key: every member becomes an admin, and rotation needs a coordinated restart (k3s, Consul).

### Gaps
- Consul ACL bootstrap and `auto_config`/`auto_encrypt` pages were not fetched.
- I found no official Syncthing doc page describing the "pending device" accept UX in detail. The config page only covers `remoteIgnoredDevice`.
- The SPAKE2 RFC text retrieved does not state its online-guess bound explicitly. That property is general PAKE knowledge, not cited here.

## mTLS (own CA) vs pinned self-signed certs vs bearer tokens; SPIFFE/SPIRE

### Takeaway
For 2–10 machines, **pinned self-signed certs (per-peer SPKI pins) or a tiny private CA**, plus a per-peer revocable credential, give most of the security with little to operate. SPIFFE/SPIRE solves workload attestation and automatic rotation across many workloads, which is a server+agent system that a handful of gateways does not need.

### Cited Findings
- Nomad's design shows a private CA plus role-encoded SANs, client-cert verification on HTTP and hot reload (SIGHUP). — [Nomad TLS](https://developer.hashicorp.com/nomad/docs/secure/traffic/tls)
- Syncthing shows the no-CA model: identity = certificate hash, and an allow-list of fingerprints. — [Syncthing security](https://docs.syncthing.net/users/security.html)
- SPIFFE defines short-lived identity documents (SVIDs) in X.509 and JWT forms. Some implementations "leverage node and/or workload attestation for issuing SVIDs" and serve the Workload API "for automatic rotation". SPIRE implements all of these, including federation. — [SPIFFE overview](https://spiffe.io/docs/latest/spiffe-about/overview/)

### Inferences
- **Bearer tokens over TLS** are the simplest manual-registration credential. They need server certificate pinning (or a public CA), or a token can be phished by a spoofed endpoint. Store only a hash on the receiving side, scope each token per peer, and allow two tokens at once during rotation.
- **Pinned self-signed certs:** no CA to protect, and revocation = delete the pin. Rotation needs an overlap window ("next pin" announced over the authenticated channel).
- **Private CA mTLS:** easier to add nodes, but revocation needs a CRL or short-lived certs, and the CA key becomes a crown jewel. For under 10 nodes, per-peer pins are simpler.
- **SPIFFE/SPIRE:** not worth it for 2–10 gateways unless the deployment already runs it. If a standard ID format is wanted, use SPIFFE-style URI SANs (`spiffe://<trust-domain>/gateway/<id>`) with no SPIRE.
- On a tailnet, WireGuard already gives mutual node authentication. App-layer mTLS is redundant there; WhoIs + CapMap is the identity.

### Gaps
- I did not fetch SPIRE operating docs (server/agent deployment, datastore), so its operational cost is my judgment, not a cited figure.

## NAT/firewall reachability without Tailscale, and the browser dashboard

### Takeaway
Without a tailnet, one side of a peer pair needs a reachable listener: an inbound port forward, a public IP, or an outbound reverse tunnel (for example Cloudflare Tunnel). A tunnel moves TLS termination and access control to the tunnel provider, which changes what "the peer's identity" means at the daemon.

### Cited Findings
- `cloudflared` makes outbound-only connections. Operators can "allow only these outbound connections and block all inbound traffic". "Authenticated Origin Pulls has no effect on hostnames routed through Cloudflare Tunnel"; origin traffic is authenticated by the tunnel's connector credentials. — [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- Tailscale Funnel, the tailnet equivalent, is public, limited to ports 443/8443/10000, and carries no identity headers. — [Tailscale KB: Funnel](https://tailscale.com/kb/1223/funnel); [Tailscale KB: Serve](https://tailscale.com/kb/1312/serve)

### Inferences
- Behind Cloudflare Tunnel (or Funnel) the edge terminates public TLS, so mTLS client certificates from peers don't reach the daemon end to end. Peer authentication then has to be an app-layer bearer token or a signed request, unless the edge enforces mTLS or service tokens. Cloudflare Access offers these, but they were not verified here.
- A browser dashboard served from one gateway that calls *other* gateways' APIs hits CORS, mixed content and certificate trust problems: browsers will not accept self-signed pinned certificates. Proxy peer calls server-side through the local gateway (browser → own gateway → peer with peer credentials), so peer credentials never reach the browser.
- Port forwarding exposes the control API to the internet. Require auth on every route, and never fall back to "discovered = trusted".

### Gaps
- Cloudflare Access service tokens and mTLS enforcement were not fetched. Check them before relying on them.
- I did not research NAT traversal without a relay (UPnP/NAT-PMP, hole punching).

## Credential rotation and revocation for peer credentials

### Takeaway
Every surveyed system rotates with an overlap window (install new, verify, switch, remove old) and revokes by deleting server-side state. Credentials that are shared or static (k3s server or agent token, Consul gossip key) are the costly ones to rotate. Per-peer credentials make revocation a single-row delete.

### Cited Findings
- Consul keyring: install → list (verify all agents) → use → remove; leftover keys are a risk. — [Consul gossip encryption](https://developer.hashicorp.com/consul/docs/secure/encryption/gossip/enable)
- k3s: bootstrap tokens expire by TTL. Server-token rotation forces a restart of all nodes, and older snapshots still need the old token. — [k3s token docs](https://docs.k3s.io/cli/token)
- Nomad: certificates hot-reload on SIGHUP, and `rpc_upgrade_mode` is a temporary mixed mode for migration. — [Nomad TLS](https://developer.hashicorp.com/nomad/docs/secure/traffic/tls)
- Syncthing: revoke a lost device by removing it from the other devices. Removal does not stick while an introducer still lists it. — [Syncthing security](https://docs.syncthing.net/users/security.html); [Syncthing introducer](https://docs.syncthing.net/users/introducer.html)
- Tailscale: tagged nodes have key expiry off by default, and changing tags does not change expiry until the node re-authenticates. — [Tailscale KB: tags](https://tailscale.com/kb/1068/tags)

### Inferences
- Recommended pattern for the gateway: per-peer record `{peer_id, cert/SPKI pin(s), token hash(es), scopes, created_at, last_seen, revoked_at}`. Rotation: the peer requests a new token or pin over the authenticated channel, both stay valid until first use of the new one or a TTL, then the old one is dropped. Revocation: set `revoked_at` and close live connections. On a tailnet, also remove the grant capability so WhoIs-based authorization fails at once.
- Enrollment tokens should be one-time with a short TTL (k3s defaults to 24 h) and bound to the expected target fingerprint.

### Gaps
- I found no primary source comparing revocation latency across these systems. This section is synthesis.

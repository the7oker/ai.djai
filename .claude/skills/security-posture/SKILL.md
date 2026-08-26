---
name: security-posture
description: Sautium's network and auth security model — what is deployed today (HMAC request signing, device tokens, self-signed TLS), the threat model it defends against, the Docker peer surface on 8801 and its trusted front, and the master node / peer-relay / carry topology. Load before touching ports, bind addresses, authentication, TLS, UPnP, or the P2P peer surface. The binding hard rules live in CLAUDE.md and apply whether or not this skill is loaded.
---

# Security posture — the full model

The prohibitions that must never be broken without asking Valerii first
are in `CLAUDE.md` § "Security Posture". This file carries the reasoning
behind them: what is deployed, what it defends against, and how the peer
network is shaped.

**Current state (as of 2026-08-21):** the backend on port 8800 has
**HMAC-SHA256 request signing** (`backend/auth_hmac.py`) and serves
**HTTPS only** with a self-signed cert (`backend/tls_gen.py`).
`backend/static/auth.js` monkey-patches `window.fetch` to sign every
request as `hex(HMAC-SHA256(key, METHOD\nPATH\nTS\nsha256(body)))`
with a 60s replay window.

The key is a **per-browser device token**, not a shared secret. The
page carries no key at all: a browser earns its token once, with the
account password (checked by re-deriving the identity — there is no
password hash anywhere) or a pairing PIN shown on the host, and keeps
it in `localStorage`, which is bound to an origin. The server never
stores tokens; it derives them as
`HMAC(server secret, "sautium-device:v1:{epoch}:{node pubkey}")`, so
bumping `auth.token_epoch` ("log out everywhere") invalidates every
copy at once, and a **different node cannot mint the same token** —
that is what the node pubkey is doing in there. Deleting a node and
creating another one therefore revokes access, which it did NOT
before 2026-08-21: both inputs used to be node-independent, so a
recreated node handed every previously paired browser full access on
a page refresh.

The **server secret** (`<p2p_identity_dir>/.api_secret`, 0600) sits
beside the identity because it is part of who the node is, not of the
code it runs — it used to live in `backend/data/` inside the checkout,
where it outlived every uninstall and was SHARED by the launcher and
Docker nodes on one machine (compose bind-mounts `./backend`). It is
still accepted as a signing key on its own, for callers that already
live on the host and read the file (launcher, MCP server): whoever can
read it has the host anyway. Four readers, all resolving the same
path — `main`, `media_urls`, `desktop/api_client`, `mcp/assistant_server`.

Unsigned requests are accepted only on the whitelist
(`WHITELIST_EXACT`/`WHITELIST_PREFIX` in `auth_hmac.py`): the page and
its static assets, `/health`, the credential checks themselves
(`/api/auth/status|login|pair|create-account` — a client with no token
cannot sign, so these defend themselves: Argon2id under a semaphore,
five PIN attempts under a lock, account creation only while the node
has no identity), and the routes that carry their own signatures
(`/api/player/media/` query params, the peer `/api/sync/` surface).

HTTPS is required because browsers gate `crypto.subtle` (the API
auth.js needs to compute HMAC) behind secure contexts — over plain
HTTP from a phone on LAN nothing can sign and the Web UI dies silently
with 401s. **HTTPS is the only listening protocol** — uvicorn binds
with `--ssl-keyfile`/`--ssl-certfile`, no HTTP fallback.

The defence layer is still the network: backend is reachable on the
LAN (so phones/tablets can use the Web UI), but **never exposed to
the public internet**. Device tokens raise the bar for hostile LAN
devices — they now have to pass the password or PIN check — but they
are not a substitute for network isolation: the self-signed cert
protects transport only, and any process running as this user can
read the secret file and sign as the host.

**The threat model we defend against right now:**

- ✅ Random internet scanners / "young hackers" probing the public
  IP — blocked because nothing forwards 8800 outside the router.
- ⚠️ Other devices on the same LAN — they can load the page, and
  that is all: it carries no key, so they must pass the account
  password or a PIN read off the host screen to earn a token. What
  is left is the strength of that password and the window in which
  a PIN is live. Accepted: this is a single-user home appliance,
  the bar is "no random scanner", not "no targeted LAN attacker".
- ✅ DNS rebinding — a page on a hostile domain whose name resolves
  to this node, talking to us from the victim's own browser. Signed
  routes never fell to it (the device token is in localStorage, bound
  to an origin the attacker lacks), but the whitelist did, and that is
  where create-account/login/pair live. `_host_allowed` in
  `auth_hmac.py` runs BEFORE the whitelist and accepts only addresses
  that are OURS — own interfaces, `SAUTIUM_HOST_IPS` (names resolved
  once at startup), `SAUTIUM_ALLOWED_HOSTS`, loopback. NOT "is it
  private": that says yes to any RFC1918 name an attacker points at
  us and no to 100.64/10, which is how a phone reaches this node over
  Tailscale. Nothing ever resolves a client-supplied name. The peer
  surface (8801) has no such guard and must not get one — it answers
  to whatever Host a UPnP-mapped port produces.
- ❌ Malicious browser extensions / processes on the host machine —
  also out of scope.

---

**A Docker node is a full peer on its own** (since the peer-port
split, 2026-07-27). libtorrent IS installed in the image
(`backend/Dockerfile`), DHT announce/lookup runs from
`backend/dht_service.py`, and `backend/p2p_app.py` serves sync, MB
slices and — since the invite-token work — the chat/relay protocol
(`backend/routers/peer_chat.py`) on 8801. What Docker still lacks is
UPnP (SSDP multicast doesn't survive the bridge), so reaching it from
the internet needs `python -m desktop.portmap map 8801` from the host
or a manual router forward. On Windows a plain `netsh portproxy` +
firewall pair (rule #3's note) gets the port through, but Docker
Desktop's user-space hops then show every peer as the bridge gateway
— no addr/subnet axes, a per-address backstop that is really global,
a probe-connect calling back the wrong host. The master therefore
runs the **trusted front** instead (`scripts/master-front/`: Caddy as
a Windows service owns :8801, terminates the peer TLS and forwards
plain HTTP + X-Forwarded-For to the loopback-only upstream
`127.0.0.1:18801`; `.env` carries `P2P_SYNC_PUBLISH=127.0.0.1:18801`
+ `P2P_TRUSTED_FRONT=1`). Native-Linux Docker (iptables DNAT) sees
real addresses and needs none of this. See P2P_NETWORK.md § "Master
behind a trusted front".

**Master node + reachability.** The maintainer's Docker node ships as
a contact in every install: `master_node.py` (mirrored
`desktop/p2p/` ↔ `backend/`) pins its invite code, full pubkey and
public support-token UUID; `P2PManager._ensure_master_contact` seeds
it as a pending friend at start (silently — deleting it sets
`p2p.master_removed` and it never comes back on its own). Nodes that
cannot accept inbound connections (CGNAT) hold an outbound SSE
subscription to `/api/relay/wake-stream` and pull chat history when
pinged, and they **suppress their own DHT announces**
(`DHTService.set_announces_enabled`) — a dead address in the DHT
helps nobody. The reachability verdict lives in `user_settings`
(`p2p.reachability`) and comes from the router WAN address, the
DHT-observed external IP, `/api/relay/probe-connect` (the relay
connects back to the request's source address, BT-tracker style) and
passive inbound traffic.

**Any reachable node is a relay** (phase D, 2026-08-06) — the master
is only relay #0, and it carries clients **under the same cap as
everyone else**. A CGNAT client registers with K=2 peer relays on top
of the master by presenting a **voucher** (its own signature over
`sautium-relay-voucher:v1:{client}:{relay}:{until}`); the relay then
announces `Sautium-user:{invite}` on its behalf (BT DHT does not
verify infohash ownership — that is the feature) and serves the same
voucher at `GET /api/relay/voucher` as proof, so a sender verifies
authority before forwarding a byte. Announce lifetime = subscription
lifetime. A friend's bare subscription carries no voucher, costs no
cap slot and produces no announce — that is the phase-A wake channel,
a different thing living on the same endpoint. Details and the
adaptive-cap rule: `P2P_NETWORK.md` § "D: Peer-relays".

**Carry and MB slices are the two push/replicate paths** (see
`P2P_NETWORK.md`). Carry pushes SEALED audio analysis to a reachable
carrier; the offer round speaks recording MBIDs and the carrier
answers with its OWN existing track uuids, so its phantom catalogue
acts as the taste filter and nothing is minted remotely. MB slices are
signed **per artist** (`mb_slice_blobs` keeps verified blobs verbatim
with the ORIGINAL dump node's signature), so any node can re-serve
names it holds — replicas are asked before dump nodes. Two rules that
look like details and are not: **a name closes only on a signed
zero-match**, and **similars are pulled for ENGAGED artists only**
(owned file or completed listen) — without that gate each hop
multiplies by a Last.fm list and the sync becomes a breadth-first
walk of all recorded music.

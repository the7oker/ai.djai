# P2P Sync Integrity — Data-Poisoning Defense

> **Status: phase 1 SHIPPED (2026-07-05/06), rest is design.** Shipped:
> per-segment + audio_features author signatures, Merkle batches, Worker
> `/timestamp` notary; **provenance refactor 2026-07-06** — content-address
> captured AT ANALYSIS TIME into `analysis_sources` (one row per
> track × physical material: pcm_hash + chromaprint + duration_seconds +
> origin local/deezer/youtube; whole owned library backfilled), records
> link via `analysis_source_id`, segments re-keyed onto `embeddings(id)`
> so segments/mean/provenance can never diverge; seal-guard DB triggers
> (payload change without new signature strips the seal — no writer can
> silently break a sealed record); record payload **v2** adds
> duration_seconds to the material declaration (cheap no-decode import
> gate; tamper-evident); tier-3 stream signing live for deezer-lossless
> sources; **Tier-0 lite on import** — signed/first-hand rows never
> overwritten by sync, `analysis_sources.imported` excludes synced-in
> provenance from signing. Still design: signed records on the wire +
> import verify, segments sync, full Tier 0 (per-node origin, purge),
> karma/verification fabric. **Origin:** poisoning concern raised by
> Valerii 2026-06-02 (verifiable/subjective split, tiers,
> master-as-cache); expanded 2026-07-03 (signature cost, atomicity,
> redistribution, Sybil mass-purge, legitimate-material ambiguity →
> content-addressing; identity certificates for cold-start weight —
> donations / birth date / proof-of-work; earned karma — dilution
> economics, timestamp priority, trap jobs; revocation protocol; karma
> curve, priority-conflict resolution, notary scaling, big-picture
> lifecycles). Updated 2026-07-05: golden age, weight-degraded
> acceptance replaces hard quarantine, mutable-source caveat, phase-1
> audio-only signing scope + possession-privacy stop on mass backfill.
> **Relates to:** `P2P_NETWORK.md` (transport & identity layer this builds
> on), `PHANTOM-DISCOVERY.md` (phantom rows sync as hints — same
> hint+local-verify rule), `desktop/sync_client.py` (the importer this
> hardens).

## Problem

Sautium's P2P network distributes audio analysis (CLAP embeddings, audio
features, BPM) and metadata (canonical names, MBIDs, tags, stats) between
collectors. A hostile actor — e.g. a competitor out to discredit the
project — can inject plausible-looking fake analysis. Once poison spreads,
detection alone doesn't help: there is no way to tell poisoned rows from
honest ones, so the network's answers degrade and trust is gone.

**Current state (2026-07):** Ed25519 signatures authenticate the *sender*
of a sync request, but nothing vouches for the *content*. Worse, the
importer takes the `source` label from the payload and applies
`ON CONFLICT DO UPDATE` — a malicious peer can spoof `source='lastfm'`
and overwrite authoritative first-party rows. The only bound today is the
friends-only (mutual-invite) topology.

## Threat model

Adversary capabilities we defend against:

- Generates keypairs for free, in bulk (**Sybil**).
- Produces fake analysis and **honestly signs it** with its own keys.
- Redistributes (re-serves) other nodes' records, mixing in fakes signed
  by throwaway keys, claiming "I just relayed it" (**deniability**).
- Sends fake accusations trying to get honest keys banned (**censorship
  via the defense mechanism itself**).

Out of scope: compromise of the user's own machine or a malicious build
of the client. Transport tampering is already covered by TLS on every
P2P connection.

## Why the naive scheme fails (design history)

The intuitive defense — sign every record, spot-check by re-hashing and
verifying the signature, broadcast-ban keys that fail — does **not** stop
the adversary above:

1. **A signature proves authorship, not truth.** The attacker signs his
   fakes honestly; every hash/signature spot-check passes perfectly.
   Signature verification only catches third-party tampering in transit —
   which TLS already prevents.
2. **Key bans don't bite.** Keygen is free; ban one key and a thousand
   pre-generated ones remain. Mass-deleting data "signed by different
   keys" is a losing whack-a-mole race.
3. **Proof-free broadcast bans are themselves a weapon.** If the network
   believes unsubstantiated "key X is poisoned" announcements, the
   cheapest attack is not poisoning — it is announcing *your* key.

The conclusions below keep the signatures (they are cheap and necessary)
but reassign their job: **attribution and evidence, not detection**.

## Core principles

1. **Signing ≠ integrity.** Signatures attribute records to keys and make
   accusations provable. They never certify content truth.
2. **Recomputation is the detector.** Audio analysis is a deterministic
   function of the audio. Whoever owns the same material can recompute
   and compare. Verification is semantic, not cryptographic.
3. **Content-addressing.** A record binds to the *specific audio
   material* it was computed from (PCM hash + acoustic fingerprint), not
   just the logical track. "Legitimately different material" then stops
   being a false-positive source.
4. **Default-deny, not blacklist.** Influence follows weight (friends,
   golden-era birth, certificates, endorsements, age) — a Sybil key's
   records may be visible, but they lose every conflict, mint no karma
   and carry an unverified label, so a thousand free keys still mean
   zero influence. Enforcement is weight degradation, not visibility
   blocking: hard quarantine was rejected (2026-07-05) as friction
   without proportional defense in a friends-first topology.
5. **Accusations carry proof; bans are local decisions.** A flag report
   embeds both signatures and both content-addresses so any owner of the
   material can independently re-verify it. No node auto-deletes on an
   unverified broadcast.
6. **Relays are accountable for their feed.** Redistribution is allowed
   (availability requires it), but the author signature is inviolable and
   the relay's own reputation backs what it re-serves.

## The big picture: a record's life, an attack's life

**A record's life.** A node computes analysis for its own files (GPU,
local). Once a day it Merkle-hashes everything new, sends the 32-byte
root to the Worker, and gets back one signed `{root, date}` stamp — one
HTTP request whether the day produced ten records or ten thousand, and
the Worker never sees the data itself. Records then travel through
ordinary sync sessions, each carrying its author signature, its content
address (`pcm_hash` + chromaprint), and its Merkle path to the stamped
root — every record independently verifiable with no callbacks. An
importing node checks signatures locally, quarantines by default, and
spot-checks a sample via the recompute ladder on material it owns;
endorsements it decides to publish ride its own next daily batch. There
is **no per-record ceremony anywhere**: ~2 notary requests per node per
day, everything else is sync traffic that happens anyway.

**Trust is a local derivative, not a transferred balance.** Nobody
"sends karma". Each node computes every author's weight for itself from
the signed facts sync already delivered: authored records with stamps,
endorsements, flag reports, trap-job grants (the only karma artifact
that exists as its own signed object — gossiped like everything else).
Like authorship in git: derived from the log, never transmitted. Trust
in a record grows monotonically as independent owners encounter and
confirm it; there is no "now it is safe" event — and no race to verify,
because unverified data is inert (default-deny), not dangerous.

**An attack's life.** Fake data from a weightless key reaches no one —
quarantine has no audience. Weight must be bought (certificates) or
earned (karma): real money, real GPU-work, or months of maturation, all
bound to one key. Published poison then meets accumulating spot-checks
(survival `(1−f)^(k·M)`), and dilution to slow them down costs ~99
honest records per fake at 1% poison. The first proven lie — the
author's own signature is the evidence — burns the key, its karma, its
certificates, and its entire purchased history; one `DELETE` per node
erases its contribution. A new key starts at zero, at full price. The
invariant that ties every section together: **the cost of a trusted
identity exceeds the payoff of the fakes it can push before it burns.**

## Data classes and their verifiers

| Class | Examples | Verifier | Defense |
|---|---|---|---|
| Verifiable by recompute | CLAP embeddings, audio features, BPM, duration | Any node owning the same material | Recompute ladder (below) |
| Verifiable by authority | MBIDs, canonical names, aliases, album existence | Local MB dump / owned-album overlap | Hint + local re-verify; never peer-driven merges |
| Subjective | similar-artist opinions, tags, curatorial notes | none (no ground truth) | Trust-based: friends-only, reputation, local flags |
| Self-reported | play stats | none | Trust-based; low blast radius, provenance-labeled |

**Mutable-source caveat (2026-07-05).** Authority- and source-fetched
data (bios, tags, external descriptions) legitimately changes upstream
over time — a bio edited on Last.fm is a new version, not a lie. A
re-fetch mismatch is therefore NOT evidence of forgery, and **flag
reports apply only to the recompute class**, where the function is
deterministic and the input is content-addressed. This also fixes the
signing rollout order: phase 1 signs audio-derived records only; what
signatures mean for source-fetched classes is an open question.

The **public/friends flag** is data-class-aware: public mode accepts only
verifiable (and verified) classes; subjective data stays friends-only.
The flag changes *exposure*, never disables defenses. Serving (privacy
exposure) and pulling (poisoning exposure) may later split into two flags.

## Signed record format

```
{
  track_uuid,        -- logical identity (UUID v5)
  pcm_hash,          -- BLAKE2b over decoded PCM samples (NOT file bytes)
  chromaprint,       -- acoustic fingerprint of the analyzed material
  model_uuid,        -- EmbeddingModel UUID v5 (existing entity)
  payload,           -- the analysis values themselves
  version,           -- monotonic per (author, track_uuid, model); replay guard
  author_pubkey,
  author_sig         -- Ed25519 over all fields above
}
+ optional endorsements: [ { endorser_pubkey, endorser_sig } ]
```

- **`pcm_hash` is over decoded samples, not the file** — FLAC compression
  level and tags change file bytes; PCM is invariant. Computed during
  analysis, when the audio is already decoded — marginal cost ~zero
  (BLAKE2b runs at ~1 GB/s).
- **`chromaprint`** distinguishes "same recording, different rip"
  (fingerprint matches, PCM differs) from "different edition/remaster"
  (fingerprint close but different) from "entirely different audio"
  (fingerprint far). New dependency: `fpcalc` (AcoustID toolchain).
- **`model_uuid`** pins the model version so recompute-verification
  compares like with like.
- **Per-record signatures, not batches.** Ed25519 signs at ~15–20k/s and
  verifies at ~7–10k/s per core (batch-verify ~2× faster): the whole
  ~35k-track library signs in seconds, once. Records stay atomic — any
  subset can be served with no batch context. Merkle trees (one signature
  per batch + a log₂(N)-hash inclusion proof per record, still atomic and
  self-verifying) are a *deferred optimization* for if record counts
  reach millions (e.g. per-window full-track analysis).

### Signing rollout & privacy (phase 1: audio-derived only)

Phase 1 signs **audio-derived records only** (embeddings, audio
features) — the deterministic, content-addressed class where a mismatch
is evidence. Source-fetched classes are excluded by the mutable-source
caveat above.

**Non-repudiation cuts both ways (Valerii, 2026-07-05).** An author
signature over a content-addressed record is a permanent, provable
statement of *possession* of that exact material. For bootlegs and other
grey-area recordings the owner may not want an eternal signed proof of
ownership traveling the network — so there is **no mass backfill
signing**, and signing one's own grey material through anonymous keys was
**rejected**: it is structurally the Sybil pattern the project defends
against (fatal optics for the founder specifically), the anonymity is
illusory (keys co-located on one node are trivially correlated), and it
merely relocates the possession proof behind a thin mask. Unsigned data
needs no such trick — it flows today, and if correct it earns weight when
a *verified owner* recomputes and endorses it.

**Three-tier signing policy (2026-07-05):**

1. **Owned-official** (provable purchases — the Bandcamp list; later an
   official-MB-release gate) → signed by the node's real identity;
   local batch re-enrich is allowed and re-signs.
2. **Grey / vinyl-rip local** → left **unsigned**; flows transport-signed
   and provenance-labeled, low weight, mints no karma. Batch re-enrich
   **skips it** — specifically, never overwrites a signed row nor
   re-derives locally what should come from a clean stream.
3. **Streamed clean source** → the key move: enrichment computed from a
   streamed official source (Deezer lossless) is signed against **the
   stream's** `pcm_hash`, not the local file's. So a grey album gets
   *signed* enrichment via its clean digital master while the local file
   stays an unsigned vinyl rip — **no possession of the bootleg is ever
   claimed**, and a verifier who owns the official version recomputes and
   confirms. Enrichment provenance (`pcm_hash`) is deliberately
   decoupled from the playback file: the signature attests to what was
   analyzed, not to what is played. This needs a provenance bit on the
   record (`origin ∈ {local, stream}`) so re-enrich knows what not to
   clobber.

**The signed and synced unit is the segment, not the mean (2026-07-05,
Valerii).** CLAP analysis is windowed — a track is a canonical 10s grid
(window `i` = `[i·10s, i·10s+10s)` from the track start), and
`embedding_segments` stores a position-indexed **subset** (K=12/16/24 by
duration); the track-level embedding is the *mean* of those segments. The
mean is **not** a verifiable unit: two honest nodes that sampled different
K produce different means from the same audio, so a signed mean cannot be
reproduced by a peer. Each **segment** is: `CLAP(PCM[i·10s:(i+1)·10s],
model)` — fully deterministic given the whole-track PCM, the index, and
the model. So segments are the verifiable primitive → **sign per segment,
sync segments, and let each node compute its own mean locally** from the
union of segments it holds (own + pulled). P2P thereby densifies the grid
— the "deepen analysis" path.

**Content-address stays whole-track.** `pcm_hash` = BLAKE2b of the
**natively-decoded** PCM (source rate & channels, f32le — *before* the
`-ac1 -ar48000` analysis conversion), plus a track-level chromaprint
(fpcalc), computed once. Hashing the native decode, not the resampled 48k
frame, is deliberate (2026-07-05, Valerii): lossless decoding is
deterministic across ffmpeg builds, whereas the resample to 48k is the one
step that can differ (swresample/soxr version) — so the content-address is
canonical for lossless material, and the resample non-determinism is
confined to the segment *recompute*, where step-2 tolerance already lives.
The 48k-mono analysis frame is a derivation defined by `grid_version`. It
stays whole-track *even though we sign segments*, because `segment_index`
is only definable in the whole-track frame. Per-slice hashing was rejected — a 10s fingerprint maps to no
external recording identity and is too noisy for the step-2 tolerance
check, and it multiplies cost 12–24× for no gain. No Merkle root either:
nodes hold different subsets, so a per-track root is not shared — each
segment is signed **independently** and is self-contained (atomic,
syncable alone).

**Chromaprint is bound into the signature from the start — never added
later (2026-07-05, Valerii).** `pcm_hash` is the brittle exact-bytes
anchor (even a different ffmpeg build shifts it); chromaprint is the
robust recording identity that makes step-2 cross-rip verification
possible. Deferring it would be a trap: adding it later changes the
payload → a new signature → a new, *later* Worker timestamp → the original
authorship priority is forfeit. So the fingerprint must be present the
first time a record is signed. (It is safe for grey material — an AcoustID
fingerprint is a public fuzzy recording ID, not a possession proof of
specific bytes; only `pcm_hash` ties to exact material, and streamed
signing uses the stream's `pcm_hash`.)

The signed segment record:

```
sautium-record:v1:segment:{author_pubkey}:{track_uuid}:{pcm_hash}:{chromaprint}
  :{model_uuid}:{grid_version}:{segment_index}:{vector_hash}
```

`audio_features` (per-track deterministic scalars) is a parallel signed
record under the same content-address:

```
sautium-record:v1:features:{author_pubkey}:{track_uuid}:{pcm_hash}:{chromaprint}
  :{analysis_version}:{features_hash}
```

**`author_pubkey` is bound INTO the payload (2026-07-05, Valerii)**, not
left as an external column, so a signature is an intrinsic statement by a
named identity — the birth certificate then vouches for that pubkey's age
and weight (the certificate rides once per author, not per record). This
does not *prevent* re-signing deterministic public content — anyone can
recompute and sign it — but it makes evidence in a flag report name its
author unambiguously and closes the class of bug where the pubkey is
treated as swappable metadata. Authorship *theft* is caught elsewhere, by
timestamp priority: a re-signer is always later, hence an endorser, not
the author.

Only hashes and IDs enter the signed string — never raw floats — so the
payload is byte-stable across signer and verifier; float determinism lives
only in computing `vector_hash`/`features_hash`, done over fixed-layout
bytes. The mean `embeddings.vector` is left unsigned — a local aggregate,
recomputed as segments accrue.

**Every signed record carries a Worker timestamp (authorship priority).**
The author signature alone proves *who*, not *when* — and for deterministic
data "when" is what defeats a plagiarist (identical content signed later =
endorser, not author; see *The karma curve* and *Notary scaling*). So
phase-1 signing is a **two-signature** flow: the node author-signs its
records, batches them into a Merkle tree, submits the **root** to the
Worker once, and gets back `sautium-timestamp:v1:{root}:{date}` signed by
the master authority. Each record then stores its author signature **plus**
a Merkle inclusion proof to that batch root and the Worker's signed
`{root, date}`. This is the per-batch notary Merkle (one Worker call per
batch, transparency-logged) — distinct from and unrelated to the rejected
per-track *content* root: nodes still hold different segment subsets, but
each node timestamps its *own* batch of signed records, and that is exactly
what a priority claim needs.

**P2P replace (signed supersedes unsigned) — deferred design.** A signed
record (typically stream-derived, official `pcm_hash`) should be able to
replace an unsigned same-track record locally and across sync. Open
questions: the audio_features/embeddings tables are keyed by `track_id`
(one row/track), so replacement is an in-place upgrade keyed on
weight (signed > unsigned) — but the two carry *different* `pcm_hash`
(stream vs rip), so "same track, better provenance" must be an explicit
upgrade rule, not a content-address match. Precedence, whether the
superseded row is retained, and sync-time conflict resolution are TBD.

## Verification ladder (recompute path)

When a node holding the audio checks a foreign record:

1. **My `pcm_hash` == record's `pcm_hash`** → recompute with
   `model_uuid` is deterministic → any mismatch is a **proven lie**.
   Strongest evidence; generates a flag report.
2. **PCM differs, chromaprint matches** (different rip of the same
   recording) → tolerance compare: cosine ≥ ~0.99 for embeddings
   (empirically stable across lossless→lossy transcodes), exact or
   ±tolerance for discrete features. Mismatch → weak, cross-rip-labeled
   report.
3. **Chromaprint differs** → different edition/remaster → **not a
   conflict**. Parallel records for different material coexist; no
   report. An honest author analyzing a remaster can never be framed as
   a poisoner by owners of the original.

**Sampling policy:** verification costs GPU-seconds per track, so it is
selective — a random ~1% of imported foreign records, plus **mandatory**
verification on any record that conflicts with a locally computed value,
plus quarantine-exit checks (below).

**Network immune system:** the more owners a track has, the more
independent verifiers exist — poisoning popular material is caught fast.
A fake bound to a `pcm_hash` that nobody owns is **self-limiting**: it
applies to material that doesn't exist in the network, so it influences
no one's search or recommendations.

## Trust & acceptance model (anti-Sybil)

**Weight-degraded acceptance (hard quarantine rejected 2026-07-05).**
Imported records are visible and usable immediately; what varies with
the author's weight is *influence*:

- Conflicts resolve by precedence: first-party > golden-era / endorsed >
  aged > fresh unverified keys. Low-weight data never overrides
  verified data — it fills gaps.
- The UI labels data from unverified sources and offers a **"verify this
  source" button** — the *human* trigger of the recompute ladder: one
  tap batch-recomputes everything from that source over the local
  library overlap → clean, or evidence + flag + purge.
- The background ladder stays on regardless (random ~1% sampling +
  mandatory recompute on conflict with a locally computed value). It is
  invisible to UX and catches the subtle poisoning no human would notice
  enough to press a button about.
- Containment is unchanged: peer data touches only reversible surfaces
  (Tier 2), and one `DELETE` per key rolls anything back.

Weight sources, strongest first:

- **Mutual-invite friends** — expensive, socially anchored keys.
- **Golden-era birth** — born_at before the network's first proven
  forgery (own section below); a mitigating factor, never an indulgence.
- **Email-verified keys** — the existing Worker CA badge; weak but real
  cost.
- **Endorsed keys** — records countersigned by nodes I already trust.
- **Identity certificates** — donation receipts, birth certificates,
  proof-of-work certificates issued by the Worker CA (own section below);
  the cold-start path for nodes without social ties.
- **Earned karma** — matured authorship, verification work, solved trap
  batches (own section below); compounds over time where certificates
  only bootstrap.
- **Key age / clean history** — earned over time, anchored by birth
  certificates.

Sybil economics collapse: a thousand free keys × zero weight = zero
influence — their records lose every conflict, mint no karma, wear the
unverified label, and a per-key purge erases any of them in one
statement. The blacklist still exists but only for the rare *expensive*
key gone rogue (a friend's compromised node), where it is cheap and
effective.

**MVP weighting is binary** (friend / email-verified / nobody). Floating
reputation scores are deferred until real abuse data justifies them.

**Accepted trade-off — cold start:** a new user without friends imports
little until they connect or verify locally. That is a product decision
(the network optimizes for trustworthy data over instant bulk), not a
technical gap — and identity certificates (below) are the deliberate
mitigation: a way to earn initial weight without social ties. The
*network's* cold start is a different problem with its own answer — the
golden age, next.

## The golden age (network-level cold start)

Proposed by Valerii 2026-07-05. Before the network is worth attacking,
nobody attacks it: early adopters are legitimate with overwhelming
probability, and defense friction (weight grinding, verification
ceremony) would punish exactly the people building the network. So the
period from launch until the **first proven forgery** is the golden age:
trust machinery is dormant, everything flows freely.

- **Golden birth is a mitigating factor, never an indulgence.** A key
  with `born_at` inside the golden era (provable — birth certificates
  are already live, and the Worker never signs a past date, so nobody
  can retro-enroll) gets a standing weight bonus. The core invariant
  still holds: weight, never immunity — a golden key caught forging
  burns exactly like any other, ladder checks apply to everyone.
- **The era ends locally, not by decree.** Each node tracks the flag
  reports it has *validated itself* (self-verifying evidence — the same
  reports that drive revocation). Accumulating validated incidents
  erode the golden bonus gradually — a fading factor, not a switch — so
  there is no global "end date" anyone must agree on and no announcement
  that could itself be attacked. Optionally, once enough weighted
  incidents accumulate, a community vote can anchor a canonical era-end
  date on the Worker for latecomers who joined after the incidents —
  mechanics deliberately left open (erosion curve, vote protocol,
  thresholds).
- **Sleeper risk, accepted knowingly:** farming golden keys requires
  knowing the project before it matters — when it is also not worth
  farming (the same asymmetry the whole idea rests on). Registration
  spikes during the quiet era are visible in the issuance transparency
  counters, and a dormant golden key that wakes up to forge still burns
  on its first proven fake.

## Identity certificates (anti-Sybil weight sources)

The Worker (today an email CA) generalizes into a lightweight certificate
authority issuing **costly identity certificates** — independent weight
markers a fresh node can earn without knowing anyone. The master public
key ships pinned in the distributive (already required for the
master-cache role). Proposed by Valerii 2026-07-03.

### Donation receipts (strongest)

After a donation, the Worker issues
`sign_master(node_pubkey, amount_tier, date)`. Sybil cost scales
**linearly in real money** — 1000 nodes × $5 = $5000 — and a key burned
on a proven fake burns the money with it. No other marker has this
economics. (Same mechanism as the deferred "PayPal CA" idea from contact
discovery, repositioned.)

- The receipt **must embed the node pubkey** — a bare receipt is
  transferable, a resale market collapses the attack cost to one
  donation.
- Privacy: the payment-identity ↔ node-key link exists only at the
  Worker; the certificate itself carries the tier, not the person.
  Blind-signature issuance (Worker signs a blinded pubkey it never sees)
  is the later privacy upgrade if that link becomes unacceptable.

### Birth certificates (key age)

The Worker signs `{node_pubkey, current_date}` — and **never a past
date** — so a key cannot be backdated. Deployment is nearly free: add
the date to the existing email-verification certificate.

- **Not** the inverted form ("Worker publishes a signed daily beacon,
  nodes keep it"): cached public beacons can be counter-signed
  retroactively by any fresh key. A bare signed date proves *freshness*
  (anti-backdating of messages), never *age*. The pubkey must be inside
  the Worker's signature.
- **Aging attack:** keys farmed today mature in a year at zero cost.
  Age is therefore a weak multiplier over other markers — ideally
  age × clean contribution history over that period — never standalone
  weight.

### Proof-of-work certificates

The Worker issues a unique challenge bound to the key —
`challenge = H(node_pubkey ‖ worker_nonce)` — and signs
`sign_master(node_pubkey, difficulty, date)` when the solution checks
out. Raises the cost of mass node creation.

- Challenge binding is mandatory: unbound puzzles can be precomputed or
  outsourced in bulk.
- **Memory-hard (Argon2id, already in the stack), not hash-hard:** plain
  SHA puzzles hand GPU farms a ~1000× edge, and the target audience owns
  RTX 4090s — so attackers do too. Argon2id narrows the gap to ~1–5×.
- Construction: find a nonce with `Argon2id(challenge ‖ nonce) < target`
  at moderate per-call parameters (~64MB / ~100ms). Difficulty is the
  expected attempt count set by the numeric target (smooth tuning,
  ~600 attempts ≈ a minute) — never by inflating a single call.
  Verification costs exactly **one full call** (~100ms): memory-hardness
  deliberately sacrifices "instant to check"; the asymmetry is
  ~attempts:1 and one call fits Worker CPU limits.
- Considered & rejected puzzles: **weakened crypto problems** (factor a
  small RSA modulus, solve a small-group ECDLP) — elegant, O(1) to
  verify, and bit-size is a natural difficulty knob (~74-bit ECDLP ≈ a
  minute on an RTX 4090) — but compute-bound: the gap between an
  optimized GPU solver and the code bundled with the client is
  100–1000×, so calibration breaks for a mixed audience and discounts
  exactly the attacker's farm. **VDFs** prove elapsed *time*, not spent
  *resources* (a many-core box runs many instances in parallel for
  cheap) — the wrong primitive for anti-Sybil.
- Rate-limit issuance on top (N certs per email/IP/day): PoW is a linear
  barrier, not a wall.

### Shared mechanics

- **Certificate = initial weight, never immunity.** Certified nodes
  still pass the recompute ladder; certificates only speed quarantine
  exit and raise serve rank. A proven fake burns the certified key and
  everything spent on it. Design invariant: **cost of an identity >
  payoff of one proven fake**.
- **Every certificate embeds the node pubkey.** Unbound receipts are
  transferable and worthless as identity.
- **Transparency counters.** The Worker publishes issuance counts
  (CT-lite — the same signed append-only head idea), so a compromised
  master key cannot *silently* mint certificates: mass minting shows up
  as a public discrepancy. Master-key compromise then degrades to
  "attacker gets initial weight faster", not a network-wide trust
  bypass — the ladder still catches the poison itself.
- **Weight portfolio** (extends the binary MVP scale when needed):
  friend > donation-cert > (email + birth + PoW) > email-only > nobody.
- **Optional accelerator, never a paywall.** A free node still joins,
  sits in quarantine, and earns weight through verified contributions —
  formalized as karma in the next section. Mandatory payment would kill
  adoption — mass adoption is the product goal.

## Earned reputation (useful work, karma)

Identity certificates are *bought* weight; karma is *earned* weight —
and the work that earns it is the same verification work the immune
system needs anyway. Proposed by Valerii 2026-07-03.

### Dilution economics (why partial poisoning doesn't pay)

An attacker publishing only fakes is caught by the first spot-check. To
hide, he must dilute with honest data: at fake fraction `f`, one
importer running `k` random checks misses him with probability
`(1−f)^k` — but checks accumulate across importers, so survival is
`(1−f)^(k·M)`, decaying toward zero as the material's owner count `M`
grows. Meanwhile:

- **Masking is linear-cost:** pushing `N` fakes at fraction `f` requires
  `~N·(1−f)/f` honest computations — real GPU-hours (at 1% poison,
  99 honest records per fake).
- **Confiscation:** the first proven fake (the author's own signature is
  the evidence) burns the key, all accumulated karma, and all the
  masking work with it.

Net: damage is bounded by `f`, cost grows as `1/f`, punishment takes
everything. A diluting attacker spends most of his budget doing the
network's work.

### The plagiarism problem

Deterministic computation makes content-authorship unprovable in
principle: the correct result for `(pcm_hash, model_uuid)` is identical
for everyone, so a copied record is indistinguishable from honest work.
Re-signing someone else's valid records would give an attacker free
"honest mass" to dilute with. Two mechanisms close this:

- **Timestamp priority.** The Worker countersigns
  `{merkle_root, date}` per published batch (RFC 3161-style, one request
  per batch). A plagiarist is provably later than the original author.
- **Dedup: second author = endorser.** The network treats the first
  published `(pcm_hash, model_uuid)` record as authorship; identical
  later records are automatically counted as endorsements. Copying
  structurally cannot mint authorship karma.

### Priority conflicts: how "earlier" is discovered and resolved

The dedup key `(pcm_hash, model_uuid)` is deterministic, so publication
naturally begins with an inventory check against peers / the master
cache: if a stamped record already exists, the new computation is
published as an endorsement in the first place. If two nodes published
independently without seeing each other (network partition), the
conflict resolves **on encounter**: compare the two notary stamps, the
earlier one keeps authorship, the later record is **reclassified** as
an endorsement — no penalty, nothing deleted, the payloads are
identical anyway. The comparison is deterministic, so every node in the
network converges to the same answer with no consensus round.

### The karma curve (enrichment is not mining)

Two collectors who own the same track do identical GPU-work and both
deserve karma — but they deliver **different value**: the first brings
data that didn't exist; the second brings an independent confirmation —
the scarcest resource the immune system has. So the reward is not
winner-takes-all, and no work is ever orphaned (unlike mining, where a
losing block is waste — here it converts into verification):

```
author > first verifier > second > … > n-th ≈ ε
```

The decay has two honest reasons. First, the marginal trust added by
the n-th confirmation falls fast. Second, a **late endorsement is
indistinguishable from free copying** — countersigning a record already
confirmed five times carries ~zero risk and proves no computation, so
paying full price for it would make copy-farming the optimal strategy.
Timestamp priority itself exists *against plagiarism* (claiming someone
else's work as your own), not to reward racing: the honest runner-up
loses only the authorship label, not the reward — his identical work
lands at the top of the verification scale.

Practical softeners: different rips → different `pcm_hash` → **both are
full authors** (cross-verified via the chromaprint bridge); every
collector's rare tail guarantees uncontested authorship somewhere; a
new `model_uuid` resets the race library-wide; trap batches pay
regardless of priority. The honest limit, stated plainly: for
bit-identical material under the same model, the second computation
earns less for equal work — the unavoidable price of determinism
(independent computation is unprovable), compensated by making that
same work the best-paid rung of verification.

### Notary scaling (why stamps stay cheap at 100k+ users)

The Worker signs **roots, not records**: a node submits 32 bytes once a
day, so notary cost is a function of *batches*, not of library size —
ten records or ten thousand, one Ed25519 signature (~50µs CPU), and the
Worker never sees the data. At Roon scale (100k nodes × ~2 requests/day
≈ 1–2 req/s) this sits in the $5–10/month Cloudflare tier; MB-scale
track counts are irrelevant because stamps cover *computation batches
per node*, not tracks. The genuinely expensive part would be the
transparency log (KV writes cost more than signatures): solved by the
Worker keeping its own Merkle log of issued stamps, publishing only the
head (CT-style) and archiving raw entries to R2 — cents per month.
Funding closes structurally: donation certificates pay for the notary
that certifies them; one free stamp per node per day (a rate limit that
doubles as anti-spam), more for weighted keys. Nor is the notary a
single point of failure: a **quorum of reputable nodes** (2–3
independent stamps ≈ one Worker stamp) or external free services
(OpenTimestamps' Bitcoin anchoring, public RFC 3161 TSAs) are drop-in
fallbacks, and a node can publish unstamped — the records work,
authorship karma just waits for a stamp (graceful degradation).

### Trap-job protocol (fast lane for newcomers)

A reputable node `R` keeps a **holdback set** — records it has computed
but not yet published. A newcomer `N` requests work; `R` issues a batch
of analysis tasks over the `R∩N` library overlap (files are never
shared, so tasks can only cover material `N` already owns; the overlap
is already exposed by inventory sync), seeding it with holdback items
`N` cannot tell apart from the rest.

- `N` cannot copy the holdback answers — they exist nowhere public.
- `R` verifies for free — it already holds the answers. This is the only
  way around the core asymmetry problem of useful work for ML:
  *checking inference normally costs a full re-inference*; here the
  checker precomputed it (the reCAPTCHA pattern, peer-to-peer).
- Matching results earn `N` karma signed by `R`; `R` then publishes the
  held-back records and rotates fresh computations in.

### Collusion and endorsement-copying

- **Karma weight = f(issuer weight).** A Sybil pair ("A issues tasks, B
  solves, A signs karma") mints nothing: zero-weight issuers grant
  zero-weight karma, and a cluster's total stays zero. Issuers stake
  their own standing — exactly like relay accountability: a node whose
  karma-grantees keep getting caught devalues all its signatures.
- **Blind endorsement is Russian roulette.** Copying a "+1" onto an
  already-endorsed record costs no work — but an endorsement is a
  signature under the content: if the record turns out poisoned (its
  early endorsers were accomplices), the copier burned himself with
  them. Early endorsements on not-yet-verified records outweigh late
  ones, and occasional trap batches calibrate whether a node actually
  computes at all.

### Three earning paths

1. **Author** — publish analysis of your own material; karma matures as
   other owners' spot-checks confirm it over time. Slow, organic,
   protected by timestamp priority.
2. **Verifier** — recompute foreign records against your own material,
   publish endorsements/flags; the network pays karma for exactly the
   work its immune system runs on.
3. **Trap-solver** — the fast lane above; available immediately given
   library overlap with a reputable node.

Karma stacks with identity certificates: certificates buy initial
weight, karma compounds it. Bootstrap: the first reputable task-issuer
is naturally the master node (already the edge-verified cache).

## Flag reports (accusation protocol)

A verifier whose ladder check fails at step 1 (or 2, weakly) publishes:

```
{
  accused_record,          -- full signed record (author's sig = the evidence)
  reporter_pcm_hash,       -- what material the reporter checked against
  reporter_chromaprint,
  reporter_value,          -- the recomputed result
  reporter_pubkey, reporter_sig
}
```

The author's own signature under the fake is **non-repudiable evidence**;
he cannot recall it. Report consumers scale their response to what they
can verify themselves:

- Same `pcm_hash` owned → full independent recompute; the report is
  self-verifying.
- Same recording, other rip → tolerant recompute.
- Material not owned → the report is testimony, weighted by the
  reporter's trust standing.

Two response layers (unchanged from the June design):

- **LOCAL** — immediate hide/override of the flagged data for the user
  who flagged it. Their node, their call. Strong, always available.
- **NETWORK** — reports are **advisory**, feeding a review queue weighted
  by friend/trusted status. Never auto-delete on crowd flags: flag
  aggregation is itself Sybil-prone (flag-bombing good data, unflagging
  poison). Ban decisions are per-node and evidence-based.

UX must distinguish **"wrong/fake"** (moderation signal, propagates
negatively, requires evidence) from **"not for me"** (personalization
signal, tunes local recommendations, never propagates).

## Revocation (how a ban works)

There is deliberately **no global ban primitive**. In a serverless
network, any authority able to delete a participant would itself be the
cheapest attack — censoring a competitor is easier than poisoning data.
A "ban" is an **emergent convergence of local decisions around
self-verifying evidence**: nobody orders it, everybody arrives at it.

**The catching node.** After a ladder step-1 mismatch (same `pcm_hash`,
same model, different result), node `V`:

1. Adds `X`'s pubkey to its local `banned_keys(pubkey, evidence, ts)`.
2. Purges `X`'s entire contribution — `DELETE ... WHERE source =
   'p2p:X'`, the one-shot rollback Tier 0's source labeling exists for.
3. Publishes the flag report (previous section).

**Propagation without commands.** Every receiver of the report
classifies itself:

- **Owns the same material** → recomputes, sees the lie first-hand,
  bans independently. For popular material this is an avalanche of
  independent convergence with no mutual trust required.
- **Owns another rip** → tolerant check, same conclusion at lower
  confidence.
- **Owns nothing** → the report is testimony. One report = nothing;
  N independent reports from weighted keys ⇒ **auto-quarantine** of
  everything from `X` (data hidden, connections suspect). Full ban only
  after own verification or an explicit user decision — never auto-ban
  on foreign words alone (flag-bombing defense).

**Why an innocent key cannot be banned.** An accusation requires a
record **signed by X** that fails recompute. Signatures are unforgeable,
so evidence against an honest author cannot be fabricated. The only lie
available to a slanderer is misreporting his own recompute of a valid
record — but material owners re-verify, find the record valid, and now
the *slanderer* has published a signed false accusation: he burns
instead. Accusing is exactly as staked as publishing.

**What burns for X:**

- His data — purged everywhere the evidence reached.
- His karma — the key *is* the karma.
- Karma he **issued** (as a trap-job issuer) — cascade devaluation: his
  signature weight drops to zero, grantees lose that component.
- His identity certificates — the Worker revokes them for that pubkey
  (a donation burns in the most literal sense).
- Relays that habitually carried him — a reputation hit
  (accountability), not a ban.

A new key restarts him at zero weight, in quarantine, at full price for
new weight. The ban need not be eternal or perfect — losing the entire
stake, every time, is the deterrent.

**Master as amplifier, not judge.** The master/Worker may run the
advisory review queue and publish a **signed revocation notice, which
must embed the same flag-report evidence**. Nodes treat it as a strong
signal (auto-quarantine), never as a verdict. Consequence: even a
compromised master key is not a censorship weapon — a notice without
valid evidence is ignored under the same rules nodes already live by.

Mechanics summary: local `banned_keys` table · sender check at sync
handshake · author-signature check at import (relayed records from
banned keys are dropped) · flag reports gossiped as ordinary sync
objects.

## Redistribution & relay accountability

Forbidding redistribution ("only serve what you signed") was considered
and **rejected**: rare data would die with its author's uptime, and the
master-cache pattern would be impossible. Instead:

- **The author signature is inviolable and travels with the record.**
  Content is path-invariant: whatever chain A→B→C it took, the signature
  either verifies or it doesn't. The distribution path therefore needs
  **no** cryptographic protection.
- **The immediate sender is always known** (P2P sessions are
  Ed25519-signed) **and accountable for its feed**, BGP-style: a relay
  that repeatedly delivers records from keys later proven poisoned
  degrades its own standing, even though it "just relayed". This removes
  the deniability the redistribution attack relies on.
- **Endorsements** let verification travel: a node that owned the
  material and ran the ladder may countersign the record. A record from
  an unknown author endorsed by a trusted node ranks far above a bare
  one.
- **Master node = edge-verified cache, never a trusted authority.** The
  shipped master invite does the MB legwork once and serves *hints*;
  every client still re-verifies against its own owned material, which
  the master cannot control. Even a fully compromised master cannot
  poison a specific client. (Rejected forms: blind-trust central
  authority — key leak poisons the whole network; reactive
  "patch+migration deletes the poison" — slow whack-a-mole.)

## Rejected: blockchain

A blockchain solves *global consensus on event ordering among mutually
distrusting parties* and charges for it with a consensus mechanism and
full replication. This design needs none of that:

- Attribution → signatures (have them).
- Revocation → per-key purge (Tier 0).
- Sybil mass-poison → default-deny weights (nothing accepted, nothing to
  purge).
- Chain-of-custody integrity → unnecessary: author signatures make
  content path-invariant (see redistribution).

The one blockchain-adjacent idea worth keeping in the back pocket is a
**signed append-only head** (certificate-transparency-lite): an author
periodically publishes `sign(merkle_root, seq)` over his own record log,
making version-replay and split-view (serving different people different
data) detectable via gossip — with zero consensus machinery. For the
MVP, the monotonic `version` field inside each signed record is enough
replay protection.

## Rollout

**Tier 0 — isolation (build first, before any wider sync):**

1. Force `source = 'p2p:' || <sender_node_id>` on every imported row —
   ignore the payload's source label. On source-keyed tables
   (`track_stats`, `lyrics`, `artist_bios`, `similar_artists`) this gives
   first-party-wins for free: peer rows land in their own keyspace and
   can never overwrite `lastfm`/`mb`/`deezer` rows.
2. `audio_features` (PK `track_id`) and `embeddings` (PK
   `track_id, model_id`) have **no source dimension** — `ON CONFLICT DO
   UPDATE` overwrites regardless. Add an origin guard (is_local flag or
   skip-if-exists): a locally-derived row is never overwritten by a peer
   row. Decide per-table.
3. Per-node purge helper: one `DELETE ... WHERE source = 'p2p:<node_id>'`
   across all enrichment tables removes a bad actor's entire
   contribution.

**Tier 1 — verification:** authority re-verify for metadata (MBID/alias
hints adopted only after owned-album-overlap / MB-dump confirmation;
structural ops — merge, rename, MBID adoption — are *never* peer-driven)
+ the recompute ladder for audio-derived data. Requires `pcm_hash` +
`chromaprint` capture at scan/analysis time and `model_uuid` in the sync
payload.

**Tier 2 — containment by reversibility:** until verified, peer data may
touch only reversible surfaces (display bios, recommendation inputs),
never the canonical identity graph.

**Tier 3 — full trust fabric:** signed record format on the wire,
quarantine store, flag reports, endorsements, binary acceptance weights.

## Open questions

- Where quarantined records live: staging tables vs. a status column on
  the target tables (leaning staging — keeps hot-path queries clean).
- Endorsement propagation format and caps (how many endorsements ride
  along with a record).
- `fpcalc`/chromaprint packaging on Windows (launcher bundles it?).
- Exact cosine threshold per feature family for ladder step 2 — needs a
  small empirical study across rips/transcodes of known-identical
  recordings.
- Whether play stats deserve any verification at all or stay
  provenance-labeled trust-only.
- Payment rails for donation receipts (PayPal first? crypto?) and
  whether amount tiers are public or just "donated: yes".
- Blind-signature issuance for donation/PoW certificates — unlinking
  payment identity from node key at the Worker.
- Holdback sizing/rotation for trap issuers — how much computed data a
  node delays publishing, and for how long.
- Karma exchange rates (trap batches vs matured authorship vs
  endorsements) — farming trap batches must never beat contributing
  fresh data.
- Auto-quarantine threshold — how many weighted foreign reports flip a
  key to suspect for nodes that cannot verify themselves.
- Golden-age mechanics: erosion curve of the golden bonus per validated
  incident, the optional vote protocol for anchoring the era end on the
  Worker, thresholds.
- Signing policy for grey material — is official-MB-release the right
  default gate? Per-album/per-artist override UX.
- Whether `embedding_segments` ever sync — if they do, `segment_root` +
  per-segment Merkle inclusion proofs activate (design ready above).

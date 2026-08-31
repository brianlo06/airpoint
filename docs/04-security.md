# Security and Privacy

## Threat model

The asset being protected is **arbitrary input to the user's Mac** — which, via the cursor and
keyboard, is close to full control of the logged-in session. That makes this a high-value target
despite being "just a remote".

| # | Adversary | Capability | Mitigation in MVP |
|---|---|---|---|
| T1 | Another device on the same LAN (guest, roommate, compromised IoT camera) | Can reach the listening port, port-scan, connect | Pairing required; connection is useless without a valid code/signature. Explicit human approval on the Mac for every first-time device. Single active pointer session. |
| T2 | Passive sniffer on shared/open Wi-Fi | Reads all traffic | TLS 1.2+ on the only listener. Nothing, including the pairing code, ever crosses the wire in clear. |
| T3 | Active MITM (ARP spoof, rogue AP) | Impersonates the Mac to the phone | QR carries the server certificate's **SPKI SHA-256 fingerprint**; the client pins it. A MITM with a different self-signed cert fails the pin. (Typed-code fallback has no pin — documented as weaker, see below.) |
| T4 | **Malicious web page** open in any browser on the phone or the Mac | Can issue cross-origin requests and `new WebSocket("wss://192.168.1.x:8443")`; can use DNS rebinding to defeat same-origin | (a) `Origin` header allowlist on upgrade — reject any origin that is not our own. (b) `Host` header allowlist — reject hosts that are not a current local IP or `<hostname>.local`, which is the DNS-rebinding defence. (c) **No ambient authority**: no cookies, no session in URL. The bearer token exists only in the page's memory, so a cross-origin socket starts unauthenticated and dies at the 5 s `hello` deadline. (d) Non-`hello` frames before auth ⇒ immediate close. |
| T5 | Brute force of the 6-digit typed code | 10⁶ space, online guessing | Code lives 90 s, is single-use, and 5 failures from one address ⇒ 15 min lockout. Effective ≈ 5 guesses per 90 s window, and **a human still has to approve**. |
| T6 | Previously-trusted device that should no longer be trusted (sold phone, ex-flatmate) | Holds a device private key | Per-device revoke in the UI, deleting the key from Keychain. "Forget all devices". Sessions expire (1 h default) and do not survive daemon restart. |
| T7 | Local malware on the Mac | Reads app files | Trusted-device public keys and the TLS private key live in the **Keychain** (`WhenUnlockedThisDeviceOnly`), not in a plist. Note honestly: malware already running as the user has bigger levers than this. |
| T8 | Someone who picks up the unlocked, paired phone | Full control while in range | Out of scope for software; mitigated by the panic disconnect on the Mac and the session idle timeout. Documented. |
| T9 | Malicious/buggy paired client | Sends hostile payloads | Every field validated against the schema in `RemoteKit`; keys come from a fixed **allowlist enum**, never raw keycodes; text length-capped and control-character-stripped; per-type token buckets; 8 KiB frame cap. |
| T10a | Someone who photographs the join code | Can attempt to pair within the code's lifetime | Only from **the same network** — the address in the code is a private one and is not routable from anywhere else. They then appear as an approval prompt on the host. For a host using multi-device codes (a game) this is the accepted trade; for the remote, the code is single-use and burned by the first device. |
| T10 | Exposure beyond the LAN | Router UPnP/port-forward, VPN | Listener binds only to interfaces with private addresses. **No UPnP, no NAT-PMP, no relay, no cloud.** Refuses to start if asked to bind a public address without an explicit `--i-know-what-im-doing` flag. |

## Pairing flow (MVP)

```
Mac                                                     Phone
 │ generate ephemeral pairing secret S (128-bit)
 │ derive 6-digit display code C (also a valid secret)
 │ show QR: airpoint://pair?h=<host>&p=<port>&f=<spki-sha256>&s=<base64 S>
 │ start 90 s TTL
 │                                    ── scan QR ──▶
 │                                                  verify TLS cert SPKI == f  (pin)
 │◀────────────── TLS connect ──────────────────────
 │ ── challenge{nonce N} ─────────────────────────▶
 │◀── hello{deviceId, name, auth:{mode:"code",
 │        proof: HMAC-SHA256(S, N ‖ deviceId)}} ────
 │ constant-time compare proof
 │ ── pair_pending ───────────────────────────────▶
 │ [ human sees "Brian's iPhone wants to control
 │   this Mac"  → Approve / Deny / Approve & Trust ]
 │ ── welcome{sessionId, expiresAt, displays} ────▶
 │ (if "Approve & Trust": store device Ed25519 pubkey in Keychain)
```

Reconnect for a trusted device: `hello{auth:{mode:"resume", sig: Ed25519(N ‖ deviceId)}}` — no code,
no approval dialog, but a **visible** menu-bar state change and a notification.

The typed-code path is identical except the QR's SPKI pin is absent, so T3 is not covered. The UI
says so: *"Scanning the QR code is more secure than typing the code."*

### Playing or controlling from another network

There is no relay, no port forwarding and no cloud, and there will not be. What works
instead is a **mesh VPN** — Tailscale, WireGuard, anything that gives both machines an
address on a private overlay. The remote device then looks like it is on the LAN, the VPN
does the authentication, and nothing is exposed to the internet.

That needs one thing from this software: Tailscale hands out addresses in 100.64.0.0/10,
which is carrier-grade NAT space. Binding it is only safe on a tunnel — on a physical
interface the same range means the *ISP's* carrier NAT, and binding that would expose input
control to strangers. So `isPrivateAddress` accepts 100.64.0.0/10 on a `utun`/`tailscale`
interface and refuses it on `en0`. Same addresses, opposite meaning, and the interface is
what distinguishes them.

Everything else still applies over the VPN: pairing, human approval, TLS, the `Origin` and
`Host` allowlists.

### Multi-device codes

A pairing code is single-use by default: it is shown to admit one device, and reusing it
would let a second in on the strength of a screenshot. A host expecting several devices to
join from one code on a television sets `consumeOnSuccess: false` on `PairingService`.

That is a real relaxation, made deliberately and only where the product requires it. What
still holds: the code expires (5 minutes), **every device is still approved by a human**,
and the five-attempt lockout is unchanged. What is given up: someone who photographs the
screen within the TTL can attempt to join — and will appear as an approval prompt on the
host, which is the control that actually matters.

**Deliberately deferred:** a PAKE (SPAKE2/CPace) would let the 6-digit code resist offline attack
and remove the pin dependency. It is the right long-term answer and is noted in the plan; for v1
the combination of short TTL, lockout, and mandatory human approval is proportionate.

## Runtime controls
- **Connection indicator**: menu-bar icon changes shape (not just colour) when a device is connected.
- **Panic disconnect**: menu-bar item and a global hotkey (default ⌥⌘Esc-adjacent, user-set) that
  kills all sessions, releases every modifier and mouse button, and stops the listener.
- **Idle timeout**: no frame for 10 s ⇒ close. Session hard-expires at 1 h.
- **One pointer at a time**: a second device may connect but is told `session_replaced` unless the
  human approves a hand-off.
- **Logging**: structured, to stderr and a rotating file. Logs event *types*, counts, latency and
  peer address. Never logs `text_input` contents, pairing secrets, tokens, or key names — a keylog
  of your own remote is still a keylog.

## Privacy
No telemetry. No network egress of any kind. No screen capture, no microphone, no clipboard read.
The daemon requests exactly one OS permission — Accessibility — and only because posting `CGEvent`s
requires it. If that permission is denied the app says so plainly and does not degrade silently.

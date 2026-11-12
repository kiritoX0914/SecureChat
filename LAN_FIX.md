# SecureChat 1.1 – LAN discovery fix (branch `lan-fix`)

This branch does **not** replace `main`. It adds a TrollStore-oriented entitlements
fake-sign, discovery-status UI, and a Connect-by-IP fallback.

## Why automatic discovery failed

The iPhone build was installed with TrollStore and never appeared under
Settings → Privacy → Local Network. iOS therefore silently blocked Bonjour /
multicast, so a Mac sharing Ethernet to that iPhone only saw its own
`_securechat._tcp` advertisement.

## What changed

- `SecureChat.entitlements` is embedded with `ldid` after the unsigned archive
  (Xcode itself is built with `CODE_SIGNING_ALLOWED=NO`).
- Entitlements used (minimal; the app is **not** unsandboxed):
  - `com.apple.developer.networking.multicast`
  - `com.apple.private.tcc.allow` → `kTCCServiceLocalNetwork`
  - `com.apple.security.network.client` / `server` (harmless)
  - `application-identifier` = `com.securechat.SecureChat`
- Listener, browser, and connections set `includePeerToPeer = true`.
- Listener binds port **47823** (falls back to a random port if busy).
- Settings and a “Connect by IP” sheet show this device’s IPv4 addresses
  (including `bridge100` / Internet Sharing) and the listening port, plus a
  host+port field that uses the same handshake as discovered peers.
- The UI reports “Local network permission denied” when Network.framework
  returns `kDNSServiceErr_PolicyDenied` (`-65570`) or `NoAuth` (`-65555`).

## How to connect by IP

1. Open SecureChat on both devices.
2. On each device open **Settings** (gear) or tap **Connect by IP** (link icon).
3. Note the IPv4 address and port shown (default port is 47823).
   If a Mac is sharing Ethernet to an iPhone, use the `bridge100` address on
   the Mac and the iPhone’s address on the shared network (often `192.168.2.x`).
4. On the other device type that IP and port and tap **Connect**.
5. The peer should appear in the chat list under its display name after the
   hello / pre-key handshake.

Install the iOS IPA with TrollStore (or Sideloadly / AltStore / 爱思助手 if
you re-sign). Re-signing with a different tool may strip the entitlements —
prefer TrollStore so `ldid` entitlements are preserved.

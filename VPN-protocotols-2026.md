# Russia VPN/Proxy Protocols That Still Work in 2026

## Executive Summary

Russia's censorship environment in 2026 is hostile to classic VPN signatures: Human Rights Watch describes a network where VPN access can fail unpredictably, and current reporting from Russian digital-rights experts says that most plain VPN protocols are now blocked while only protocols that convincingly disguise themselves as ordinary network traffic still work reliably.[^1][^2] The strongest 2026 options are **VLESS + REALITY**, **NaiveProxy**, **AmneziaWG 2.0**, and **Hysteria 2**, with **TUIC** as a conditional option rather than a default.[^2][^3][^4][^5][^6] Plain **WireGuard**, **OpenVPN**, and unwrapped **Shadowsocks** should no longer be treated as primary protocols for Russia; if they are used at all, they need extra camouflage layers such as prefixes or pluggable transports.[^2][^5][^7][^8][^9] In practice, "works in 2026" means "still has credible evidence of working when well configured and kept updated," not "always connects from every ISP or region."[^1][^2]

## Russia's 2026 censorship model

Russia's current filtering model is built around centrally managed DPI/TSPU infrastructure rather than simple website blocks, which gives authorities the ability to inspect, throttle, reset, and reroute traffic at protocol level across provider networks.[^1] Government Decree No. 1667, adopted in late 2025 and entering into force in March 2026, further formalized Roskomnadzor's centralized authority to manage technical countermeasures and issue binding instructions to network participants.[^10] Contemporary reporting also describes active pressure on app stores, VPN-related websites, and server IP ranges, so protocol stealth alone is no longer enough; the transport also needs operational flexibility such as rotation, multiple endpoints, and alternative access paths.[^1][^2]

## What characteristics still help in 2026

The protocols that still look viable in Russia share a small set of properties:

| Property | Why it matters in Russia | Protocols that benefit |
| --- | --- | --- |
| Looks like real HTTPS / HTTP/2 / HTTP/3 | Russia's filtering increasingly targets non-standard or obviously encrypted tunnel signatures, so blending into mainstream web traffic reduces the censor's precision.[^1][^2][^3][^4] | VLESS+REALITY, NaiveProxy, Hysteria 2 |
| Avoids static handshake fingerprints | Plain WireGuard and OpenVPN are easier to detect because their handshakes and header patterns are stable and well known.[^5][^9][^11] | REALITY, NaiveProxy, AmneziaWG |
| Survives active probing | Active probing remains a practical censor technique for proxy discovery, so transports that hide behind normal reverse proxies or valid web behavior age better.[^4][^8][^12] | NaiveProxy, Cloak, modern Shadowsocks variants |
| Can vary packet sizes / headers | Fixed packet sizes and predictable headers make DPI rules easier to write and maintain.[^5][^7][^8][^9] | AmneziaWG 2.0, NaiveProxy, modern Shadowsocks implementations |
| Has multiple clients and active maintenance | Russia-specific blocking changes quickly, so transport ecosystems that update frequently are materially more resilient.[^2][^4][^5][^6] | Xray/REALITY, NaiveProxy, Hysteria 2, AmneziaWG |

## Protocol-by-protocol assessment

### 1. VLESS + REALITY (Xray) - **best default**

**Why it still works:** REALITY is explicitly designed to replace ordinary server-side TLS with a flow that is indistinguishable from a chosen real TLS destination, while removing the server TLS fingerprint and avoiding the need for your own public certificate setup.[^3] The official REALITY documentation also notes that it can point to someone else's website, present genuine-looking TLS for a chosen SNI, and is intended specifically to avoid the detectable patterns that ordinary TLS-based proxying creates.[^3] That matches what Russian experts are reporting on the ground: Xray-family protocols, especially VLESS-based deployments, are still among the protocols that generally continue to work in Russia when configured well.[^2]

**Why it ranks first:** It combines a mature tooling ecosystem, many clients, low operational overhead for self-hosting, and a transport profile that fits the core lesson of the 2026 Russian environment: successful protocols must look like something the censor cannot cheaply block without collateral damage.[^2][^3]

**Main weakness:** The REALITY authors warn that pairing REALITY with other proxy protocols that preserve obvious "TLS inside TLS" traits is not recommended because those traits are already targeted; in other words, the safest Xray pattern is still the clean VLESS/XTLS/REALITY path rather than every possible Xray combination.[^3]

### 2. NaiveProxy - **best HTTPS-looking fallback**

**Why it still works:** NaiveProxy reuses Chromium's network stack specifically to minimize detectable differences from normal Chrome traffic, and its README calls out resistance against traffic classification, TLS parameter fingerprinting, active probing, and simple length analysis.[^4] It does this by looking like ordinary HTTP/2 or HTTP/3 CONNECT traffic routed through mainstream frontends such as Caddy or HAProxy rather than a custom tunnel with a bespoke handshake.[^4] Russian experts cited by TechRadar also list NaiveProxy among the protocols that generally still function in 2026.[^2]

**Why it ranks second:** If the threat model is "make the tunnel look as much like a browser as possible," NaiveProxy is one of the cleanest answers available today because its camouflage is built on Chrome's own stack rather than on a thin imitation.[^4]

**Main weakness:** The project itself documents trade-offs: TLS-over-TLS overhead, some remaining traffic-shape quirks, and a need to stay current so the signature matches current Chrome behavior.[^4] That makes NaiveProxy operationally heavier than VLESS+REALITY even if its camouflage is excellent.[^4]

### 3. AmneziaWG 2.0 - **best WireGuard-style option for Russia**

**Why it still works:** AmneziaWG exists specifically because plain WireGuard became too easy to fingerprint. The official docs describe it as a WireGuard fork that removes identifiable network signatures, adds dynamic headers, randomizes packet sizes, and can mimic common UDP protocols such as QUIC and DNS.[^5] Amnezia says version 2.0 extends that approach from handshake obfuscation to ongoing traffic mimicry so that DPI systems have a harder time using stable header and packet-size patterns.[^5] TechRadar's reporting from Amnezia's founder says the protocol remains stable overall in Russia, though signatures do get periodically blocked and require regular updates.[^2]

**Why it ranks third:** It preserves the ergonomic and performance advantages people like about WireGuard, but it is one of the few protocols whose design has clearly been shaped around the exact DPI problem Russia now presents.[^2][^5]

**Main weakness:** It is still fundamentally UDP-oriented. That matters because Russian censors reportedly almost completely blocked unidentified UDP traffic during parts of 2025, forcing Amnezia to harden the protocol further.[^2] AmneziaWG therefore looks strong, but it is best treated as an actively maintained anti-DPI branch of WireGuard, not as a "set and forget" protocol.[^2][^5]

### 4. Hysteria 2 - **strong but UDP-sensitive**

**Why it still works:** Hysteria 2 is built on a customized QUIC transport and explicitly states that it masquerades as standard HTTP/3 traffic, which is exactly the kind of cover that still appears viable in Russia when properly configured.[^6] Russian experts quoted in 2026 reporting include Hysteria among the protocols that generally still work.[^2]

**Why it ranks fourth:** It is very fast, supports multiple deployment modes, and benefits from the fact that blocking all HTTP/3-looking traffic is expensive for the censor.[^6]

**Main weakness:** QUIC and UDP are also where Russia has been most aggressive recently. TechRadar's reporting says unidentified UDP was almost completely blocked during part of 2025, and that matters for any QUIC-based transport if its camouflage is weak or its behavior drifts away from ordinary HTTP/3.[^2] Hysteria is therefore a good secondary path, but a risky single point of failure.

### 5. TUIC - **conditional / advanced-user option**

**Why it can work:** TUIC is a QUIC-based proxy protocol built for low-latency TCP and UDP relay, with 0-RTT support, multiplexing, connection migration, and implementations across multiple clients and servers.[^11][^13] On paper, those are attractive properties for censorship circumvention because QUIC can blend into widely used web traffic and avoids some of TCP's obvious tunnel bottlenecks.[^11][^13]

**Why it does not rank higher:** I did not find the same level of Russia-specific 2026 field evidence for TUIC that exists for Xray/REALITY, NaiveProxy, Hysteria, or AmneziaWG.[^2] Given Russia's increased hostility to suspicious UDP, TUIC looks plausible but more conditional than the top four.[^2][^11][^13]

### 6. Shadowsocks / Outline with modern hardening - **backup, not primary**

**Why it still matters:** Shadowsocks is still actively hardened. Outline documents mandatory AEAD ciphers, probing resistance, replay protection, variable first-packet sizing, and a "connection prefix disguise" feature added to help the client resemble allowed protocols when fully encrypted traffic is being blocked.[^7][^9] That means modern Shadowsocks is materially better than the old "random encrypted blob" reputation some people still associate with it.[^7][^9]

**Why it ranks low anyway:** Russia's current filtering seems harsher than the environment where modern Shadowsocks regained ground. Reporting on Russian blocking now says Shadowsocks and other "unidentified" encrypted flows are increasingly targeted heuristically, while local experts say the protocols that still work are the ones that convincingly masquerade as other protocols rather than just staying encrypted.[^2][^12] In other words, Shadowsocks is now best seen as a fallback with prefixes, wrappers, or special client support, not as the primary 2026 answer for Russia.[^2][^7][^9]

### 7. OpenVPN, WireGuard, IKEv2 without camouflage - **do not use as primary**

**Why they fail:** VPNLab's Russia-focused analysis says WireGuard and OpenVPN were among the first protocols neutralized by protocol-level blocking, while Amnezia's own technical explanation of AmneziaWG starts from the same premise: plain WireGuard exposes fixed headers and predictable packet sizes that make DPI straightforward.[^5][^12] WireGuard's own protocol description also confirms its very distinct UDP-based handshake and packet structure, which is part of why it performs well but also why it is easy to fingerprint.[^14] Amnezia's product README reinforces the practical distinction by separating "classic VPN protocols" like OpenVPN and WireGuard from protocols with masking and obfuscation such as XRay, OpenVPN+Cloak, Shadowsocks wrapping, and AmneziaWG.[^8]

**Bottom line:** These protocols are still useful inside friendly networks or as business VPNs on approved paths, but they are poor choices for a Russian anti-censorship stack unless wrapped in a stronger camouflage layer.[^2][^8][^12]

## Wrappers and camouflage layers that still matter

### Cloak

Cloak is not a VPN by itself; it is a pluggable transport that can front tools such as OpenVPN, Shadowsocks, or Tor and make them look like ordinary web traffic.[^15] Its README emphasizes probe resistance, browser-like behavior, reverse-proxy integration, and even CDN-assisted transport, which makes it relevant if you must keep a legacy protocol for client compatibility.[^15] In 2026 it should be treated as a wrapper strategy, not a first-choice protocol family.

### Prefixing / disguise for modern Shadowsocks

Outline's maintainers explicitly added connection-prefix disguise so that Shadowsocks initialization can look like an allowed protocol when fully encrypted traffic is being blocked.[^9] That is useful as a fallback path, especially where you already have Outline clients deployed, but it still sits below REALITY or NaiveProxy in my ranking because it is compensating for a weaker native traffic shape rather than starting from one that already resembles ordinary browser traffic.[^3][^4][^9]

## Recommended 2026 ranking for self-hosted use in Russia

| Rank | Protocol / stack | 2026 verdict |
| --- | --- | --- |
| 1 | **VLESS + REALITY (Xray)** | Best all-around default for self-hosted access in Russia today.[^2][^3] |
| 2 | **NaiveProxy** | Best browser-like HTTPS fallback; excellent against fingerprinting, but higher operational overhead.[^2][^4] |
| 3 | **AmneziaWG 2.0** | Best WireGuard-derived option when Russia-specific anti-DPI support is needed.[^2][^5] |
| 4 | **Hysteria 2** | Good high-speed secondary path; weaker as a sole protocol because of UDP pressure.[^2][^6] |
| 5 | **TUIC** | Plausible advanced option, but less directly validated in Russia-specific 2026 reporting.[^2][^11][^13] |
| 6 | **Shadowsocks / Outline with prefixes or wrappers** | Useful backup, not the first line anymore.[^7][^9][^12] |
| 7 | **Plain WireGuard / OpenVPN / IKEv2** | Poor primary choice against current Russian DPI.[^5][^8][^12][^14] |

## What this means for the current `hogen-vpn` project

For this repository specifically, the architectural direction is already aligned with the strongest current evidence because it uses **VLESS + REALITY** as the full-tunnel protocol.[^2][^3] The practical next step for resilience is not replacing that stack, but **adding a second independent fallback transport** so users are not dependent on a single protocol family when regional or ISP-specific blocking changes suddenly.[^1][^2] The strongest fallback candidate is **NaiveProxy** if you want a TCP/HTTPS-looking backup, while **AmneziaWG 2.0** is the strongest candidate if you want a WireGuard-like user experience with Russia-specific anti-DPI changes.[^4][^5]

I would **not** redesign the stack around plain WireGuard, plain OpenVPN, or plain Shadowsocks in 2026.[^2][^5][^8][^12] If a legacy path is still needed for compatibility, it should be treated as a wrapped or disguised backup rather than the primary route.[^9][^15]

## Confidence Assessment

**High confidence**

- Russia's filtering stack is increasingly centralized, DPI-driven, and hostile to classic VPN signatures.[^1][^2][^10]
- VLESS + REALITY, NaiveProxy, Hysteria, and AmneziaWG are the most credible protocol families still reported as usable in Russia in 2026.[^2][^3][^4][^5][^6]
- Plain WireGuard and OpenVPN are poor defaults under current Russian conditions.[^2][^5][^8][^12][^14]

**Medium confidence**

- My exact ordering between **NaiveProxy**, **AmneziaWG 2.0**, and **Hysteria 2** may vary by ISP, device mix, and whether the operator values TCP-like camouflage or UDP performance more.[^2][^4][^5][^6]
- TUIC probably works in some cases, but I found less Russia-specific evidence for it than for the other top contenders.[^2][^11][^13]

**Lower confidence / intentionally omitted**

- I did not find strong enough 2026 evidence to rank **MTProxy** as a general-purpose answer; it remains Telegram-specific and should not be treated as a substitute for a full anti-censorship transport stack.
- I excluded more speculative or narrower transports unless I found both a credible technical description and some Russia-specific relevance.

## Footnotes

[^1]: Human Rights Watch, *Disrupted, Throttled, and Blocked: State Censorship, Control, and Increasing Isolation of Internet Users in Russia* (2025), https://www.hrw.org/report/2025/07/30/disrupted-throttled-and-blocked/state-censorship-control-and-increasing-isolation
[^2]: TechRadar, *Russia's battle against VPNs is entering a new phase: Here's what to expect in 2026* (2026), https://www.techradar.com/vpn/vpn-services/russias-battle-against-vpns-is-entering-a-new-phase-heres-what-to-expect-in-2026
[^3]: [XTLS/REALITY](https://github.com/XTLS/REALITY), `README.en.md`, https://github.com/XTLS/REALITY/blob/main/README.en.md
[^4]: [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy), `README.md`, https://github.com/klzgrad/naiveproxy/blob/master/README.md
[^5]: Amnezia documentation, *AmneziaWG*, https://docs.amnezia.org/documentation/amnezia-wg/
[^6]: [apernet/hysteria](https://github.com/apernet/hysteria), `README.md`, https://github.com/apernet/hysteria/blob/master/README.md and https://v2.hysteria.network/
[^7]: [OutlineFoundation/outline-server](https://github.com/OutlineFoundation/outline-server), `docs/shadowsocks.md`, https://github.com/OutlineFoundation/outline-server/blob/master/docs/shadowsocks.md
[^8]: [amnezia-vpn/amnezia-client](https://github.com/amnezia-vpn/amnezia-client), `README.md`, https://github.com/amnezia-vpn/amnezia-client/blob/dev/README.md
[^9]: [OutlineFoundation/outline-server](https://github.com/OutlineFoundation/outline-server), repository README plus Shadowsocks anti-detection notes, https://github.com/OutlineFoundation/outline-server and https://github.com/OutlineFoundation/outline-server/blob/master/docs/shadowsocks.md
[^10]: Digital Policy Alert, *Government adopted Decree No. 1667 on approval of the Rules for centralised management of the public communications network* (2025/2026), https://digitalpolicyalert.org/event/35363-government-adopted-decree-no-1667-on-approval-of-the-rules-for-centralised-management-of-the-public-communications-network-including-government-access-to-data
[^11]: [tuic-protocol/tuic](https://github.com/tuic-protocol/tuic), repository README and spec links, https://github.com/tuic-protocol/tuic
[^12]: VPNLab, *Total VPN Blocking in Russia 2025: TSPU vs WireGuard and Shadowsocks*, https://vpnlab.io/en/total-blocking-of-vpn-traffic-in-russia-235
[^13]: [Itsusinn/tuic](https://github.com/Itsusinn/tuic), repository README, https://github.com/Itsusinn/tuic
[^14]: WireGuard, *Protocol Overview*, https://www.wireguard.com/protocol/
[^15]: [cbeuw/Cloak](https://github.com/cbeuw/Cloak), repository README, https://github.com/cbeuw/Cloak

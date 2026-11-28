//! Shared network safety (SSRF/redirect validation), bounded HTTP streaming readers,
//! and crash-safe atomic file persistence helpers for `charkle-core`.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::Path;
use std::time::Duration;

use reqwest::redirect::Policy;
use url::{Host, Url};
use uuid::Uuid;

/// Returns `true` strictly for globally routable public IP addresses.
/// Rejects loopback, RFC1918 private, link-local (including cloud metadata 169.254.169.254),
/// CGNAT (100.64.0.0/10), multicast, broadcast, unspecified, IPv6 ULA/link-local,
/// IPv4-mapped IPv6 (`::ffff:a.b.c.d`), IPv4-compatible IPv6, and NAT64 (`64:ff9b::/96`).
pub fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_ipv4(v4),
        IpAddr::V6(v6) => is_public_ipv6(v6),
    }
}

fn is_public_ipv4(v4: Ipv4Addr) -> bool {
    if v4.is_loopback()
        || v4.is_private()
        || v4.is_link_local()
        || v4.is_broadcast()
        || v4.is_documentation()
        || v4.is_unspecified()
        || v4.is_multicast()
    {
        return false;
    }
    let o = v4.octets();
    // 0.0.0.0/8 ("this network")
    if o[0] == 0 {
        return false;
    }
    // 100.64.0.0/10 (Carrier-Grade NAT / Shared Address Space, RFC 6598)
    if o[0] == 100 && (64..=127).contains(&o[1]) {
        return false;
    }
    // 192.0.0.0/24 (IETF Protocol Assignments)
    if o[0] == 192 && o[1] == 0 && o[2] == 0 {
        return false;
    }
    // 198.18.0.0/15 (Benchmarking, RFC 2544)
    if o[0] == 198 && (o[1] == 18 || o[1] == 19) {
        return false;
    }
    // 240.0.0.0/4 (Reserved / Class E)
    if o[0] >= 240 {
        return false;
    }
    true
}

fn is_public_ipv6(v6: Ipv6Addr) -> bool {
    if v6.is_loopback() || v6.is_unspecified() || v6.is_multicast() {
        return false;
    }
    let segs = v6.segments();
    // IPv4-mapped IPv6 (::ffff:a.b.c.d) and IPv4-compatible IPv6 (::a.b.c.d)
    if segs[0..5] == [0, 0, 0, 0, 0] && (segs[5] == 0xffff || segs[5] == 0) {
        let v4 = Ipv4Addr::new(
            (segs[6] >> 8) as u8,
            (segs[6] & 0xff) as u8,
            (segs[7] >> 8) as u8,
            (segs[7] & 0xff) as u8,
        );
        return is_public_ipv4(v4);
    }
    // NAT64 well-known prefix (64:ff9b::/96)
    if segs[0] == 0x0064 && segs[1] == 0xff9b && segs[2..6] == [0, 0, 0, 0] {
        let v4 = Ipv4Addr::new(
            (segs[6] >> 8) as u8,
            (segs[6] & 0xff) as u8,
            (segs[7] >> 8) as u8,
            (segs[7] & 0xff) as u8,
        );
        return is_public_ipv4(v4);
    }
    // Unique local (fc00::/7)
    if (segs[0] & 0xfe00) == 0xfc00 {
        return false;
    }
    // Link-local unicast (fe80::/10) and deprecated site-local (fec0::/10)
    if (segs[0] & 0xffc0) == 0xfe80 || (segs[0] & 0xffc0) == 0xfec0 {
        return false;
    }
    // Documentation range (2001:db8::/32)
    if segs[0] == 0x2001 && segs[1] == 0x0db8 {
        return false;
    }
    true
}

/// Validates that `url` targets a public external HTTP(S) host without embedded credentials,
/// loopback/private/metadata IP literals, IPv4-mapped IPv6 literals, or local-only hostnames.
pub fn is_safe_public_url(url: &Url, require_https: bool) -> bool {
    let scheme_ok = if require_https {
        url.scheme().eq_ignore_ascii_case("https")
    } else {
        matches!(url.scheme(), "http" | "https")
    };
    if !scheme_ok {
        return false;
    }
    if !url.username().is_empty() || url.password().is_some() {
        return false;
    }
    let Some(host) = url.host() else {
        return false;
    };
    match host {
        Host::Ipv4(v4) => is_public_ipv4(v4),
        Host::Ipv6(v6) => is_public_ipv6(v6),
        Host::Domain(raw) => {
            let trimmed = raw.trim().trim_end_matches('.').to_ascii_lowercase();
            if trimmed.is_empty()
                || !trimmed.contains('.')
                || trimmed == "localhost"
                || trimmed.ends_with(".localhost")
                || trimmed.ends_with(".local")
                || trimmed.ends_with(".localdomain")
                || trimmed.ends_with(".internal")
                || trimmed.ends_with(".home.arpa")
                || trimmed == "metadata.google.internal"
            {
                return false;
            }
            let unbracketed = trimmed
                .strip_prefix('[')
                .and_then(|s| s.strip_suffix(']'))
                .unwrap_or(&trimmed);
            if let Ok(ip) = unbracketed.parse::<IpAddr>() {
                return is_public_ip(ip);
            }
            true
        }
    }
}

/// Performs syntactic public URL validation followed by async DNS resolution verification
/// so hostnames resolving to loopback/private/link-local/metadata IPs are rejected before connect.
pub async fn validate_public_url_with_dns(url: &Url, require_https: bool) -> Result<(), String> {
    if !is_safe_public_url(url, require_https) {
        return Err(format!(
            "Rejected unsafe or non-public URL: {}",
            url.as_str()
        ));
    }
    let Some(host_str) = url.host_str() else {
        return Err("URL missing host".to_string());
    };
    let port = url.port_or_known_default().unwrap_or(443);
    let lookup_target = format!("{host_str}:{port}");
    let addrs = tokio::time::timeout(
        Duration::from_secs(5),
        tokio::net::lookup_host(lookup_target.as_str()),
    )
    .await
    .map_err(|_| "DNS lookup timed out".to_string())?
    .map_err(|e| format!("DNS lookup failed: {e}"))?;

    let mut resolved_any = false;
    for sock_addr in addrs {
        resolved_any = true;
        if !is_public_ip(sock_addr.ip()) {
            return Err(format!(
                "Blocked host resolving to non-public IP: {}",
                sock_addr.ip()
            ));
        }
    }
    if !resolved_any {
        return Err("DNS lookup returned no addresses".to_string());
    }
    Ok(())
}

/// Builds a `reqwest` redirect policy that validates every hop before following it.
pub fn public_redirect_policy(max_hops: usize, require_https: bool) -> Policy {
    Policy::custom(move |attempt| {
        if attempt.previous().len() >= max_hops {
            return attempt.error("Too many redirects");
        }
        if !is_safe_public_url(attempt.url(), require_https) {
            return attempt.error("Blocked redirect to unsafe or non-public URL");
        }
        attempt.follow()
    })
}

/// Builds a `reqwest` redirect policy that blocks cross-origin and HTTPS->HTTP downgrade redirects.
pub fn same_origin_no_downgrade_redirect_policy(max_hops: usize) -> Policy {
    Policy::custom(move |attempt| {
        if attempt.previous().len() >= max_hops {
            return attempt.error("Too many redirects");
        }
        if let Some(first) = attempt.previous().first() {
            let was_https = first.scheme().eq_ignore_ascii_case("https");
            let now_https = attempt.url().scheme().eq_ignore_ascii_case("https");
            if was_https && !now_https {
                return attempt.error("Blocked HTTPS to HTTP redirect downgrade");
            }
            if first.origin() != attempt.url().origin() {
                return attempt.error("Blocked cross-origin redirect");
            }
        }
        attempt.follow()
    })
}

/// Streams a `reqwest::Response` body up to `max_bytes`, aborting immediately if exceeded.
pub async fn read_bounded_bytes(
    resp: &mut reqwest::Response,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    if let Some(declared) = resp.content_length() {
        if declared > max_bytes as u64 {
            return Err(format!(
                "Response Content-Length ({declared}) exceeds {max_bytes} byte limit"
            ));
        }
    }
    let initial_cap = resp
        .content_length()
        .map(|n| (n as usize).min(max_bytes).min(256 * 1024))
        .unwrap_or(0);
    let mut out = Vec::with_capacity(initial_cap);
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| format!("Failed reading HTTP response stream: {e}"))?
    {
        if out.len().saturating_add(chunk.len()) > max_bytes {
            return Err(format!(
                "Response body exceeded {max_bytes} byte safety limit"
            ));
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

/// Streams a `reqwest::Response` body as UTF-8 text up to `max_bytes`.
pub async fn read_bounded_text(
    resp: &mut reqwest::Response,
    max_bytes: usize,
) -> Result<String, String> {
    let bytes = read_bounded_bytes(resp, max_bytes).await?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Persists `bytes` to `path` via a unique sibling temporary file and safe swap so
/// concurrent writers never collide on a fixed `.tmp` path and failures never delete `path`.
pub fn write_bytes_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("data.bin");
    let tmp = path.with_file_name(format!("{file_name}.{}.tmp", Uuid::new_v4().simple()));
    if let Err(err) = std::fs::write(&tmp, bytes) {
        let _ = std::fs::remove_file(&tmp);
        return Err(err);
    }
    match std::fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(rename_err) => {
            let backup =
                path.with_file_name(format!("{file_name}.{}.bak", Uuid::new_v4().simple()));
            let moved_orig = std::fs::rename(path, &backup).is_ok();
            match std::fs::rename(&tmp, path) {
                Ok(()) => {
                    if moved_orig {
                        let _ = std::fs::remove_file(&backup);
                    }
                    Ok(())
                }
                Err(_) => {
                    if moved_orig {
                        let _ = std::fs::rename(&backup, path);
                    }
                    let _ = std::fs::remove_file(&tmp);
                    Err(rename_err)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_url_guard_blocks_loopback_private_cgnat_and_ipv4_mapped_ipv6() {
        for bad in [
            "http://127.0.0.1/secret",
            "https://[::1]/secret",
            "http://[::ffff:127.0.0.1]/secret",
            "https://[::ffff:169.254.169.254]/latest/meta-data/",
            "https://[64:ff9b::127.0.0.1]/",
            "https://100.64.0.1/internal",
            "https://169.254.169.254/latest/meta-data/",
            "https://10.0.0.5/",
            "https://192.168.1.1/",
            "https://localhost./api",
            "https://foo.localhost/api",
            "https://user:pass@example.com/a.jpg",
            "file:///C:/Windows/win.ini",
        ] {
            let u = Url::parse(bad).expect("parse bad url");
            assert!(!is_safe_public_url(&u, false), "must reject {bad}");
        }

        let good = Url::parse("https://pbs.twimg.com/media/sample.jpg").unwrap();
        assert!(is_safe_public_url(&good, true));
        let http_good = Url::parse("http://example.com/a.png").unwrap();
        assert!(is_safe_public_url(&http_good, false));
        assert!(!is_safe_public_url(&http_good, true));
    }
}

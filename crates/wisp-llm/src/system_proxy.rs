//! OS system-proxy lookup used only to name the proxy in transport errors.
//!
//! Matches reqwest's default client: macOS `SCDynamicStore` and Windows
//! Internet Settings. Environment variables are handled separately by
//! [`super::ambient_proxy_env`].

/// HTTPS (then HTTP) system proxy reqwest would use when Settings is empty
/// and no `HTTP(S)_PROXY` is set. `None` on Linux, where reqwest only follows
/// the environment.
pub fn ambient_system_proxy() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        macos_system_https_proxy()
    }
    #[cfg(windows)]
    {
        windows_system_https_proxy()
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        None
    }
}

#[cfg(any(test, target_os = "macos", windows))]
pub(crate) fn http_proxy_url(host: &str, port: Option<i32>) -> Option<String> {
    proxy_url("http", host, port)
}

#[cfg(any(test, windows))]
fn socks_proxy_url(host: &str, port: Option<i32>) -> Option<String> {
    proxy_url("socks5", host, port)
}

#[cfg(any(test, target_os = "macos", windows))]
fn proxy_url(scheme: &str, host: &str, port: Option<i32>) -> Option<String> {
    let host = host.trim();
    if host.is_empty() {
        return None;
    }
    if host.contains("://") {
        return Some(host.to_string());
    }
    match port.filter(|port| *port > 0) {
        Some(port) => Some(format!("{scheme}://{host}:{port}")),
        None => match host.rsplit_once(':') {
            Some((_, suffix)) if suffix.parse::<u16>().is_ok() => {
                Some(format!("{scheme}://{host}"))
            }
            _ => Some(format!("{scheme}://{host}")),
        },
    }
}

/// Prefer HTTPS, then HTTP, then SOCKS from a Windows `ProxyServer` value.
#[cfg(any(test, windows))]
pub(crate) fn windows_proxy_server_https(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    if !value.contains('=') {
        return http_proxy_url(value, None);
    }
    let mut http = None;
    let mut https = None;
    let mut socks = None;
    for part in value.split(';') {
        let Some((scheme, addr)) = part.split_once('=') else {
            continue;
        };
        match scheme.trim().to_ascii_lowercase().as_str() {
            "https" => https = http_proxy_url(addr, None),
            "http" => http = http_proxy_url(addr, None),
            "socks" | "socks5" => socks = socks_proxy_url(addr, None),
            _ => {}
        }
    }
    https.or(http).or(socks)
}

#[cfg(target_os = "macos")]
fn macos_system_https_proxy() -> Option<String> {
    use system_configuration::dynamic_store::SCDynamicStoreBuilder;
    use system_configuration::sys::schema_definitions::{
        kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPPort, kSCPropNetProxiesHTTPProxy,
        kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSPort, kSCPropNetProxiesHTTPSProxy,
    };

    let store = SCDynamicStoreBuilder::new("wisp-science").build()?;
    let proxies = store.get_proxies()?;
    macos_proxy_from_store(
        &proxies,
        unsafe { kSCPropNetProxiesHTTPSEnable },
        unsafe { kSCPropNetProxiesHTTPSProxy },
        unsafe { kSCPropNetProxiesHTTPSPort },
    )
    .or_else(|| {
        macos_proxy_from_store(
            &proxies,
            unsafe { kSCPropNetProxiesHTTPEnable },
            unsafe { kSCPropNetProxiesHTTPProxy },
            unsafe { kSCPropNetProxiesHTTPPort },
        )
    })
}

#[cfg(target_os = "macos")]
fn macos_proxy_from_store(
    proxies: &system_configuration::core_foundation::dictionary::CFDictionary<
        system_configuration::core_foundation::string::CFString,
        system_configuration::core_foundation::base::CFType,
    >,
    enabled_key: system_configuration::core_foundation::string::CFStringRef,
    host_key: system_configuration::core_foundation::string::CFStringRef,
    port_key: system_configuration::core_foundation::string::CFStringRef,
) -> Option<String> {
    use system_configuration::core_foundation::number::CFNumber;
    use system_configuration::core_foundation::string::CFString;

    let enabled = proxies
        .find(enabled_key)
        .and_then(|flag| flag.downcast::<CFNumber>())
        .and_then(|flag| flag.to_i32())
        .unwrap_or(0)
        == 1;
    if !enabled {
        return None;
    }
    let host = proxies
        .find(host_key)
        .and_then(|host| host.downcast::<CFString>())
        .map(|host| host.to_string())?;
    let port = proxies
        .find(port_key)
        .and_then(|port| port.downcast::<CFNumber>())
        .and_then(|port| port.to_i32());
    http_proxy_url(&host, port)
}

#[cfg(windows)]
fn windows_system_https_proxy() -> Option<String> {
    let settings = windows_registry::CURRENT_USER
        .open(r"Software\Microsoft\Windows\CurrentVersion\Internet Settings")
        .ok()?;
    if settings.get_u32("ProxyEnable").unwrap_or(0) == 0 {
        return None;
    }
    windows_proxy_server_https(&settings.get_string("ProxyServer").ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_proxy_url_adds_scheme_and_port() {
        assert_eq!(
            http_proxy_url("127.0.0.1", Some(10080)).as_deref(),
            Some("http://127.0.0.1:10080")
        );
        assert_eq!(
            http_proxy_url("127.0.0.1:10080", None).as_deref(),
            Some("http://127.0.0.1:10080")
        );
        assert_eq!(http_proxy_url("  ", Some(80)), None);
    }

    #[test]
    fn windows_proxy_server_prefers_https_then_http() {
        assert_eq!(
            windows_proxy_server_https("127.0.0.1:10080").as_deref(),
            Some("http://127.0.0.1:10080")
        );
        assert_eq!(
            windows_proxy_server_https("http=127.0.0.1:10080;https=127.0.0.1:8443").as_deref(),
            Some("http://127.0.0.1:8443")
        );
        assert_eq!(
            windows_proxy_server_https("socks=127.0.0.1:10081").as_deref(),
            Some("socks5://127.0.0.1:10081")
        );
        assert_eq!(windows_proxy_server_https("  "), None);
    }
}

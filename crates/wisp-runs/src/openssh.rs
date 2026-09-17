//! Local OpenSSH client version gate.
//!
//! Wisp password auth sets `SSH_ASKPASS_REQUIRE=force`, which OpenSSH added in
//! 8.4. Windows inbox OpenSSH is often 8.1 and silently ignores that variable,
//! so saved passwords never reach `ssh` and persistent runtimes time out.

use std::process::Stdio;
use std::sync::OnceLock;

/// OpenSSH 8.4 added `SSH_ASKPASS_REQUIRE`.
pub const MIN_OPENSSH_VERSION: OpenSshVersion = OpenSshVersion { major: 8, minor: 4 };

pub const OPENSSH_TOO_OLD_MARKER: &str = "Local OpenSSH is too old";
pub const OPENSSH_MISSING_MARKER: &str = "OpenSSH client was not found";
pub const OPENSSH_UNPARSED_MARKER: &str = "Could not parse local OpenSSH";

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct OpenSshVersion {
    pub major: u32,
    pub minor: u32,
}

impl std::fmt::Display for OpenSshVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

/// Parse `ssh -V` banners such as `OpenSSH_8.1p1` and `OpenSSH_for_Windows_9.5p1`.
pub fn parse_openssh_version_banner(banner: &str) -> Result<OpenSshVersion, String> {
    let Some(start) = banner.find("OpenSSH") else {
        return Err(unparsed_error(banner));
    };
    let after_name = &banner[start + "OpenSSH".len()..];
    let rest = after_name
        .trim_start_matches(|c: char| c == '_' || c.is_ascii_alphabetic())
        .trim_start_matches('_')
        .trim_start();
    let (major, rest) = take_u32(rest).ok_or_else(|| unparsed_error(banner))?;
    let rest = rest
        .strip_prefix('.')
        .ok_or_else(|| unparsed_error(banner))?;
    let (minor, _) = take_u32(rest).ok_or_else(|| unparsed_error(banner))?;
    Ok(OpenSshVersion { major, minor })
}

pub fn require_openssh_banner(banner: &str) -> Result<OpenSshVersion, String> {
    let version = parse_openssh_version_banner(banner)?;
    if version < MIN_OPENSSH_VERSION {
        Err(too_old_error(version))
    } else {
        Ok(version)
    }
}

/// Run `ssh -V` once per process and require OpenSSH 8.4 or later.
pub fn require_local_openssh() -> Result<OpenSshVersion, String> {
    static DETECTED: OnceLock<Result<OpenSshVersion, String>> = OnceLock::new();
    DETECTED.get_or_init(detect_local_openssh).clone()
}

fn detect_local_openssh() -> Result<OpenSshVersion, String> {
    require_openssh_banner(&read_local_openssh_banner()?)
}

fn read_local_openssh_banner() -> Result<String, String> {
    let mut cmd = std::process::Command::new("ssh");
    cmd.arg("-V")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    wisp_tools::process::hide_console(&mut cmd);
    match cmd.output() {
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            let banner = if stderr.trim().is_empty() {
                stdout.trim()
            } else {
                stderr.trim()
            };
            if banner.is_empty() {
                Err(unparsed_error(""))
            } else {
                Ok(banner.to_string())
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Err(missing_error()),
        Err(error) => Err(format!("failed to run `ssh -V`: {error}")),
    }
}

fn take_u32(input: &str) -> Option<(u32, &str)> {
    let end = input
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(input.len());
    if end == 0 {
        return None;
    }
    input[..end]
        .parse()
        .ok()
        .map(|value| (value, &input[end..]))
}

fn too_old_error(found: OpenSshVersion) -> String {
    format!(
        "{OPENSSH_TOO_OLD_MARKER} for Wisp (found OpenSSH {found}, need {MIN_OPENSSH_VERSION} or later). \
         Password authentication uses SSH_ASKPASS_REQUIRE, which OpenSSH added in {MIN_OPENSSH_VERSION}. \
         {}",
        upgrade_help()
    )
}

fn missing_error() -> String {
    format!(
        "{OPENSSH_MISSING_MARKER} on PATH. Wisp needs OpenSSH {MIN_OPENSSH_VERSION} or later (`ssh -V`). \
         {}",
        upgrade_help()
    )
}

fn unparsed_error(banner: &str) -> String {
    if banner.trim().is_empty() {
        format!(
            "{OPENSSH_UNPARSED_MARKER} version from empty `ssh -V` output. \
             Wisp needs OpenSSH {MIN_OPENSSH_VERSION} or later. {}",
            upgrade_help()
        )
    } else {
        format!(
            "{OPENSSH_UNPARSED_MARKER} version from `ssh -V` output: {banner}. \
             Wisp needs OpenSSH {MIN_OPENSSH_VERSION} or later. {}",
            upgrade_help()
        )
    }
}

fn upgrade_help() -> &'static str {
    if cfg!(windows) {
        "Windows inbox OpenSSH 8.1 cannot supply saved passwords. Update OpenSSH Client in Settings → Apps → Optional features, or install a current build from https://github.com/PowerShell/Win32-OpenSSH/releases. Confirm `where ssh` points at the new binary, restart Wisp, and run `ssh -V`."
    } else {
        "Install OpenSSH 8.4 or later from your package manager (Homebrew: `brew install openssh`) and ensure that `ssh` is first on PATH. Restart Wisp and confirm with `ssh -V`."
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_openssh_banners() {
        let cases = [
            ("OpenSSH_8.1p1, LibreSSL 2.7.3", 8, 1),
            ("OpenSSH_for_Windows_8.1p1, LibreSSL 3.0.2", 8, 1),
            ("OpenSSH_8.4p1", 8, 4),
            ("OpenSSH_8.6p1, LibreSSL 3.3.6", 8, 6),
            (
                "OpenSSH_9.5p1 Microsoft_Windows_OpenSSH-for-Windows_9.5.4.1",
                9,
                5,
            ),
            (
                "OpenSSH_9.9p1 Ubuntu-3ubuntu3.1, OpenSSL 3.0.13 30 Jan 2024",
                9,
                9,
            ),
            ("OpenSSH_10.0p2", 10, 0),
            ("ssh: OpenSSH_8.6p1, LibreSSL 3.3.6", 8, 6),
            ("OpenSSH 8.4", 8, 4),
        ];
        for (banner, major, minor) in cases {
            assert_eq!(
                parse_openssh_version_banner(banner).unwrap(),
                OpenSshVersion { major, minor },
                "{banner}"
            );
        }
    }

    #[test]
    fn rejects_unrecognized_banners() {
        for banner in ["", "Dropbear v2022.83", "ssh version unknown", "OpenSSH"] {
            let error = parse_openssh_version_banner(banner).unwrap_err();
            assert!(
                error.contains(OPENSSH_UNPARSED_MARKER),
                "banner {banner:?}: {error}"
            );
        }
    }

    #[test]
    fn eight_four_is_the_minimum() {
        assert!(require_openssh_banner("OpenSSH_8.4p1").is_ok());
        assert!(require_openssh_banner("OpenSSH_9.0p1").is_ok());
        let old = require_openssh_banner("OpenSSH_for_Windows_8.1p1").unwrap_err();
        assert!(old.contains(OPENSSH_TOO_OLD_MARKER), "{old}");
        assert!(old.contains("found OpenSSH 8.1"), "{old}");
        assert!(old.contains("need 8.4"), "{old}");
        let older = require_openssh_banner("OpenSSH_7.9p1").unwrap_err();
        assert!(older.contains(OPENSSH_TOO_OLD_MARKER), "{older}");
    }

    #[test]
    fn installed_ssh_v_is_parseable_when_present() {
        let mut cmd = std::process::Command::new("ssh");
        cmd.arg("-V")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        wisp_tools::process::hide_console(&mut cmd);
        let Ok(output) = cmd.output() else {
            return;
        };
        let mut banner = String::from_utf8_lossy(&output.stderr).into_owned();
        if banner.trim().is_empty() {
            banner = String::from_utf8_lossy(&output.stdout).into_owned();
        }
        let banner = banner.trim();
        if banner.is_empty() {
            return;
        }
        parse_openssh_version_banner(banner)
            .unwrap_or_else(|error| panic!("could not parse `{banner}`: {error}"));
    }
}

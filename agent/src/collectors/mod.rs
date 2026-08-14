//! Platform-neutral inventory facade with operating-system-specific backends.

use crate::{cancellation::Cancellation, payload::ServerResource};
use std::fmt;

#[cfg(target_os = "linux")]
mod filesystem_facts;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
mod network_facts;
mod system_facts;

#[derive(Debug)]
pub struct CollectError(pub String);

impl fmt::Display for CollectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CollectError {}

/// Capabilities are selected by the active backend so future platforms can
/// advertise a smaller supported inventory surface without changing transport.
pub fn capabilities() -> Vec<&'static str> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        vec!["host.inventory"]
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        Vec::new()
    }
}

pub fn collect(cancellation: &Cancellation) -> Result<ServerResource, CollectError> {
    #[cfg(target_os = "linux")]
    {
        linux::collect(cancellation)
    }

    #[cfg(target_os = "macos")]
    {
        macos::collect(cancellation)
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        Err(CollectError(format!(
            "no inventory collector is implemented for {} yet",
            std::env::consts::OS
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::capabilities;

    #[test]
    #[cfg(target_os = "linux")]
    fn linux_backend_advertises_host_inventory() {
        assert_eq!(capabilities(), ["host.inventory"]);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn macos_backend_advertises_host_inventory() {
        assert_eq!(capabilities(), ["host.inventory"]);
    }
}

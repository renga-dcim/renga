//! Platform-neutral inventory facade with operating-system-specific backends.

use crate::payload::ServerResource;
use std::fmt;

#[cfg(target_os = "linux")]
mod linux;

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
    #[cfg(target_os = "linux")]
    {
        vec!["host.inventory"]
    }

    #[cfg(not(target_os = "linux"))]
    {
        Vec::new()
    }
}

pub fn collect() -> Result<ServerResource, CollectError> {
    #[cfg(target_os = "linux")]
    {
        linux::collect()
    }

    #[cfg(not(target_os = "linux"))]
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
}

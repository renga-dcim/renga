//! Host agent workspace entry crate.
//!
//! The service implementation lands in a later phase; this crate keeps the
//! repository's Rust lint and test targets active from the start.

/// Returns true when the agent crate is linked and callable.
pub fn crate_ready() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::crate_ready;

    #[test]
    fn crate_is_ready() {
        assert!(crate_ready());
    }
}

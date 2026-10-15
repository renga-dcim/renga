//! Agent logging with dependency-level credential redaction.

use tracing::Subscriber;
use tracing_subscriber::{
    filter::{filter_fn, FilterExt},
    fmt::MakeWriter,
    layer::SubscriberExt,
    EnvFilter, Layer, Registry,
};

// Tungstenite 0.30 serializes the complete upgrade request, including the
// credential-bearing subprotocol, before tracing it from this target.
const SENSITIVE_HANDSHAKE_TARGET: &str = "tungstenite::handshake::client";

/// Builds the production subscriber. The deny filter is composed after the
/// operator's environment filter, so `RUST_LOG` cannot re-enable this target.
pub fn subscriber<W>(writer: W, environment: EnvFilter) -> impl Subscriber + Send + Sync
where
    W: for<'writer> MakeWriter<'writer> + Send + Sync + 'static,
{
    let safe = environment.and(filter_fn(|metadata| {
        metadata.target() != SENSITIVE_HANDSHAKE_TARGET
    }));

    Registry::default().with(
        tracing_subscriber::fmt::layer()
            .json()
            .with_writer(writer)
            .with_filter(safe),
    )
}

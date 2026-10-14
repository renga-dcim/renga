//! `inventory.collect@1`: run the agent's normal inventory collection now.
//!
//! The observation travels through the ordinary observation queue, and the
//! job reports only its ID, so the job adds no power over the host. Matches
//! `Renga.Jobs.Capabilities.InventoryCollect`.

use super::{Capability, JobFailure, RetryClass, RiskClass};
use crate::cancellation::Cancellation;
use serde_json::{json, Value};
use std::time::Duration;
use uuid::Uuid;

/// Collects, queues, and delivers one observation, returning its ID.
pub type Collect = dyn Fn(&Cancellation) -> Result<Uuid, String> + Send + Sync;

pub struct InventoryCollect {
    collect: Box<Collect>,
}

impl InventoryCollect {
    pub fn new(collect: Box<Collect>) -> Self {
        Self { collect }
    }
}

impl Capability for InventoryCollect {
    fn name(&self) -> &'static str {
        "inventory.collect"
    }

    fn version(&self) -> u32 {
        1
    }

    fn risk_class(&self) -> RiskClass {
        RiskClass::Observe
    }

    fn retry_class(&self) -> RetryClass {
        RetryClass::Idempotent
    }

    fn timeout(&self) -> Duration {
        Duration::from_secs(300)
    }

    fn run(&self, parameters: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        // A collection is always the agent's configured one.
        let empty = parameters.is_null() || parameters.as_object().is_some_and(|p| p.is_empty());
        if !empty {
            return Err(JobFailure::Failed(
                "inventory.collect@1 takes no parameters".into(),
            ));
        }
        match (self.collect)(cancellation) {
            Ok(observation_id) => Ok(json!({ "observation_id": observation_id })),
            Err(_) if cancellation.cancelled() => Err(JobFailure::Cancelled),
            Err(reason) => Err(JobFailure::Failed(reason)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_the_delivered_observation_id() {
        let id = Uuid::new_v4();
        let capability = InventoryCollect::new(Box::new(move |_| Ok(id)));
        assert_eq!(capability.key(), "inventory.collect@1");
        assert_eq!(
            capability.run(&json!({}), &Cancellation::default()),
            Ok(json!({ "observation_id": id }))
        );
    }

    #[test]
    fn rejects_parameters_and_maps_failures() {
        let capability = InventoryCollect::new(Box::new(|_| Err("collector failed".into())));
        assert!(matches!(
            capability.run(&json!({"path": "/"}), &Cancellation::default()),
            Err(JobFailure::Failed(_))
        ));
        assert_eq!(
            capability.run(&json!({}), &Cancellation::default()),
            Err(JobFailure::Failed("collector failed".into()))
        );

        let cancelled = Cancellation::default();
        cancelled.cancel();
        assert_eq!(
            capability.run(&json!({}), &cancelled),
            Err(JobFailure::Cancelled)
        );
    }
}

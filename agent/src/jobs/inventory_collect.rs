//! `inventory.collect@1`: run the agent's normal inventory collection now.
//!
//! The observation travels through attempt-bound protected admission, and the
//! job reports only its durably accepted ID. Matches
//! `Renga.Jobs.Capabilities.InventoryCollect`.

use super::{Capability, JobFailure, RetryClass, RiskClass};
use crate::cancellation::Cancellation;
use crate::payload::LeasedJob;
use serde_json::{json, Value};
use std::time::Duration;
use uuid::Uuid;

/// Collects and durably submits one protected observation, returning its ID.
pub type Collect = dyn Fn(&LeasedJob, &Cancellation) -> Result<Uuid, JobFailure> + Send + Sync;

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
        let _ = (parameters, cancellation);
        Err(JobFailure::Failed(
            "inventory collection requires leased attempt authority".into(),
        ))
    }

    fn evidence_limit(&self) -> (u32, u64) {
        (1, crate::payload::MAX_OBSERVATION_BYTES as u64)
    }

    fn run_leased(
        &self,
        job: &LeasedJob,
        cancellation: &Cancellation,
    ) -> Result<Value, JobFailure> {
        // A collection is always the agent's configured one.
        let parameters = &job.parameters;
        let empty = parameters.is_null() || parameters.as_object().is_some_and(|p| p.is_empty());
        if !empty {
            return Err(JobFailure::Failed(
                "inventory.collect@1 takes no parameters".into(),
            ));
        }
        match (self.collect)(job, cancellation) {
            Ok(observation_id) => Ok(json!({ "observation_id": observation_id })),
            Err(_) if cancellation.cancelled() => Err(JobFailure::Cancelled),
            Err(reason) => Err(reason),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(parameters: Value) -> LeasedJob {
        serde_json::from_value(json!({
            "id": Uuid::new_v4(), "capability": "inventory.collect@1", "parameters": parameters,
            "attempt": 1, "lease_token": "token", "lease_expires_at": "2026-11-10T13:00:00Z",
            "timeout_ms": 300000, "output_limit_bytes": 65536
        }))
        .unwrap()
    }

    #[test]
    fn reports_the_delivered_observation_id() {
        let id = Uuid::new_v4();
        let capability = InventoryCollect::new(Box::new(move |_, _| Ok(id)));
        assert_eq!(capability.key(), "inventory.collect@1");
        assert_eq!(
            capability.run_leased(&job(json!({})), &Cancellation::default()),
            Ok(json!({ "observation_id": id }))
        );
    }

    #[test]
    fn rejects_parameters_and_maps_failures() {
        let capability = InventoryCollect::new(Box::new(|_, _| {
            Err(JobFailure::Failed("collector failed".into()))
        }));
        assert!(matches!(
            capability.run_leased(&job(json!({"path": "/"})), &Cancellation::default()),
            Err(JobFailure::Failed(_))
        ));
        assert_eq!(
            capability.run_leased(&job(json!({})), &Cancellation::default()),
            Err(JobFailure::Failed("collector failed".into()))
        );

        let cancelled = Cancellation::default();
        cancelled.cancel();
        assert_eq!(
            capability.run_leased(&job(json!({})), &cancelled),
            Err(JobFailure::Cancelled)
        );
    }
}

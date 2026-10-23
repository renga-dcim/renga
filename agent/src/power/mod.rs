//! Host power readings, delivered as telemetry (RFD 10, "Host agent").
//!
//! A module thread samples the host's power sensors on its own interval and queues each sample
//! set as one telemetry batch, so a slow sensor never holds up inventory or lease check-ins.

pub mod hwmon;
pub mod pdu;

use crate::{
    cancellation::Cancellation,
    payload::{
        PowerSourceReport, SampleMapping, SampleWindow, TelemetryBatch, TelemetrySample,
        MAX_TELEMETRY_BYTES,
    },
    snmp::worker::Sink,
};
use chrono::{DateTime, Utc};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, PoisonError},
    thread,
    time::{Duration, Instant},
};
use tracing::{debug, warn};

/// How often the host's power sensors are sampled.
pub const SAMPLE_INTERVAL: Duration = Duration::from_secs(60);
/// How long Renga may treat a reading as current. It covers a missed sample and the delivery
/// worker's flush interval, after which an outage leaves load unknown rather than stale.
pub const FRESH_FOR_SECONDS: u32 = 300;
const WAIT_SLICE: Duration = Duration::from_millis(250);

/// The latest status of each of the host's power sources, by source name, for check-ins.
#[derive(Clone, Default)]
pub struct PowerSources(Arc<Mutex<BTreeMap<String, &'static str>>>);

impl PowerSources {
    pub fn status(&self, source: &str) -> Option<&'static str> {
        self.lock().get(source).copied()
    }

    pub fn hwmon(&self) -> Option<&'static str> {
        self.status(hwmon::MAPPING)
    }

    /// Every source sampled so far, or `None` before the first sample, so a check-in keeps the
    /// last report rather than replacing it with nothing.
    pub fn reports(&self) -> Option<Vec<PowerSourceReport>> {
        let sources = self.lock();
        (!sources.is_empty()).then(|| {
            sources
                .iter()
                .map(|(source, status)| PowerSourceReport {
                    source: source.clone(),
                    status,
                })
                .collect()
        })
    }

    pub fn publish(&self, source: &str, status: &'static str) {
        self.lock().insert(source.to_owned(), status);
    }

    /// Forgets the sources `keep` rejects, such as exporters a reload removed.
    pub fn retain(&self, keep: impl Fn(&str) -> bool) {
        self.lock().retain(|source, _status| keep(source));
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, &'static str>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The running power module; dropping it stops the thread.
pub struct PowerModule {
    stop: Cancellation,
}

impl PowerModule {
    /// Samples immediately, then every `SAMPLE_INTERVAL`, queuing each batch through `sink`.
    pub fn start(sink: Sink, sources: PowerSources) -> Self {
        let stop = Cancellation::default();
        let thread_stop = stop.clone();
        if let Err(error) = thread::Builder::new()
            .name("power".into())
            .spawn(move || run(&PathBuf::from(hwmon::ROOT), &thread_stop, &sink, &sources))
        {
            warn!(%error, "cannot start the power module");
        }
        Self { stop }
    }
}

impl Drop for PowerModule {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

fn run(root: &Path, stop: &Cancellation, sink: &Sink, sources: &PowerSources) {
    while !stop.cancelled() {
        let started = Instant::now();
        sample(root, Utc::now(), sink, sources);
        while !stop.cancelled() && started.elapsed() < SAMPLE_INTERVAL {
            thread::sleep(WAIT_SLICE);
        }
    }
}

/// Reads the sensors once and queues their batch, if any sensor is mapped.
fn sample(root: &Path, now: DateTime<Utc>, sink: &Sink, sources: &PowerSources) {
    let scan = hwmon::scan(root);
    sources.publish(hwmon::MAPPING, scan.availability.as_str());
    if scan.readings.is_empty() {
        debug!(
            availability = scan.availability.as_str(),
            "no mapped host power sensors"
        );
        return;
    }
    let batch = batch(&scan.readings, now);
    match serde_json::to_vec(&batch) {
        Ok(body) if body.len() <= MAX_TELEMETRY_BYTES => sink(batch.replay_id, &body),
        Ok(body) => warn!(
            bytes = body.len(),
            "host power batch too large; dropping it"
        ),
        Err(error) => warn!(%error, "cannot encode host power batch"),
    }
}

/// The host batch for readings taken at `now`.
pub fn batch(readings: &[hwmon::Reading], now: DateTime<Utc>) -> TelemetryBatch {
    TelemetryBatch::host(
        readings
            .iter()
            .map(|reading| to_sample(reading, now))
            .collect(),
    )
}

fn to_sample(reading: &hwmon::Reading, now: DateTime<Utc>) -> TelemetrySample {
    // hwmon bounds a window to a day, so the start is always representable.
    let start = chrono::Duration::from_std(reading.window)
        .ok()
        .and_then(|window| now.checked_sub_signed(window))
        .unwrap_or(now);
    let (status, value) = match &reading.watts {
        Ok(watts) => ("valid", Some(*watts)),
        Err(error) => {
            warn!(sensor = %reading.sensor, error = %error.message, "cannot read power sensor");
            ("failed", None)
        }
    };
    TelemetrySample {
        target: None,
        sensor: reading.sensor.clone(),
        boundary: reading.boundary.as_str(),
        quantity: "real_power",
        unit: Some("W"),
        component: None,
        leg: None,
        coverage: None,
        status,
        origin: "native",
        value,
        state: None,
        window: SampleWindow { start, end: now },
        event_at: now,
        mapping: SampleMapping {
            name: hwmon::MAPPING,
            version: hwmon::MAPPING_VERSION,
        },
        fresh_for_seconds: FRESH_FOR_SECONDS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use std::fs;
    use uuid::Uuid;

    type Batches = Arc<Mutex<Vec<(Uuid, Value)>>>;

    fn capture() -> (Sink, Batches) {
        let batches = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&batches);
        let sink: Sink = Arc::new(move |id, body: &[u8]| {
            captured
                .lock()
                .unwrap()
                .push((id, serde_json::from_slice(body).unwrap()));
        });
        (sink, batches)
    }

    #[test]
    fn queues_one_host_batch_per_sample_with_failures_as_unknown() {
        // A fake /sys with two PMBus supplies described in the devicetree.
        let sys = std::env::temp_dir().join(format!("renga-power-{}", Uuid::new_v4()));
        let root = sys.join("class/hwmon");
        for (index, value) in [(0, "245500000"), (1, "busy")] {
            let chip = root.join(format!("hwmon{index}"));
            let device = sys.join(format!("devices/platform/i2c-3/3-006{index}"));
            let node = sys.join(format!(
                "firmware/devicetree/base/i2c@1e78a400/psu@6{index}"
            ));
            for dir in [&chip, &device, &node] {
                fs::create_dir_all(dir).unwrap();
            }
            std::os::unix::fs::symlink(&node, device.join("of_node")).unwrap();
            std::os::unix::fs::symlink(&device, chip.join("device")).unwrap();
            fs::write(chip.join("name"), "ibm_cffps1\n").unwrap();
            fs::write(chip.join("power1_label"), "pin\n").unwrap();
            fs::write(chip.join("power1_average"), value).unwrap();
            fs::write(chip.join("power1_average_interval"), "30000").unwrap();
        }
        let (sink, batches) = capture();
        let sources = PowerSources::default();
        let now = DateTime::parse_from_rfc3339("2026-10-22T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        sample(&root, now, &sink, &sources);
        fs::remove_dir_all(&sys).unwrap();

        assert_eq!(sources.hwmon(), Some("available"));
        let batches = batches.lock().unwrap();
        let [(replay_id, batch)] = batches.as_slice() else {
            panic!("expected one batch, got {batches:?}");
        };
        assert_eq!(batch["replay_id"], replay_id.to_string());
        assert_eq!(batch["version"], 1);
        assert!(batch.get("collector").is_none());
        assert_eq!(
            batch["samples"][0],
            json!({
                "sensor": "ibm_cffps1/dt:i2c@1e78a400/psu@60/power1",
                "boundary": "supply_input",
                "quantity": "real_power",
                "unit": "W",
                "status": "valid",
                "origin": "native",
                "value": 245.5,
                "window": {"start": "2026-10-22T11:59:30Z", "end": "2026-10-22T12:00:00Z"},
                "event_at": "2026-10-22T12:00:00Z",
                "mapping": {"name": "hwmon", "version": 1},
                "fresh_for_seconds": 300
            })
        );
        assert_eq!(batch["samples"][1]["status"], "failed");
        assert!(batch["samples"][1].get("value").is_none());
    }

    #[test]
    fn nothing_is_reported_before_the_first_sample() {
        assert_eq!(PowerSources::default().reports(), None);
    }

    #[test]
    fn a_host_without_mapped_sensors_queues_nothing() {
        let root = std::env::temp_dir().join(format!("renga-power-{}", Uuid::new_v4()));
        let (sink, batches) = capture();
        let sources = PowerSources::default();

        sample(&root, Utc::now(), &sink, &sources);

        assert!(batches.lock().unwrap().is_empty());
        assert_eq!(sources.hwmon(), Some("not_present"));
        assert_eq!(
            sources.reports(),
            Some(vec![PowerSourceReport {
                source: "hwmon".into(),
                status: "not_present"
            }])
        );
    }
}

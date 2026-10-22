//! Power readings from local Prometheus exporters (RFD 10, "Local Prometheus exporters").
//!
//! Hosts that already run node_exporter or ipmi_exporter can let the agent read them instead of
//! granting it more privilege. Each configured endpoint is scraped on its own thread through the
//! bounded fetch in [`fetch`], parsed by the bounded reader in [`text`], and reduced to the fixed
//! [`mapping`]. Readings travel as host telemetry with `origin: "exporter"`, so a native reading
//! of the same boundary wins over them.

pub mod fetch;
pub mod mapping;
pub mod text;

use crate::{
    cancellation::Cancellation,
    payload::{
        SampleComponent, SampleMapping, SampleWindow, TelemetryBatch, TelemetrySample,
        MAX_TELEMETRY_BYTES,
    },
    power::{PowerSources, FRESH_FOR_SECONDS},
    snmp::worker::Sink,
};
use chrono::{DateTime, Utc};
use fetch::{Endpoint, FetchError};
use mapping::{Measurement, Reading};
use serde::Deserialize;
use std::{
    path::PathBuf,
    thread,
    time::{Duration, Instant},
};
use tracing::{info, warn};
use url::Url;

pub const EXPORTERS_MAX: usize = 16;
const INTERVAL_DEFAULT: u64 = 60;
const TIMEOUT_DEFAULT: u64 = 10;
const TIMEOUT_MAX: u64 = 30;
/// node_exporter's full output on a large host is a few megabytes.
const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const WAIT_SLICE: Duration = Duration::from_millis(250);

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawExporter {
    url: Option<String>,
    allow_remote: Option<bool>,
    bearer_token_file: Option<PathBuf>,
    interval_seconds: Option<u64>,
    timeout_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exporter {
    pub endpoint: Endpoint,
    pub interval: Duration,
}

impl Exporter {
    /// How check-ins name this source.
    pub fn source(&self) -> &str {
        self.endpoint.url.as_str()
    }
}

/// Validates `[[exporters]]`. The URL may carry no credentials or query, since it is reported
/// in check-ins; a token comes only from `bearer_token_file`, and only for a remote endpoint.
pub fn from_raw(raw: Vec<RawExporter>) -> Result<Vec<Exporter>, String> {
    if raw.len() > EXPORTERS_MAX {
        return Err(format!(
            "exporters must have at most {EXPORTERS_MAX} entries"
        ));
    }
    let mut exporters: Vec<Exporter> = Vec::new();
    for (index, raw) in raw.into_iter().enumerate() {
        let at = format!("exporters[{index}]");
        let url = raw.url.ok_or_else(|| format!("{at}.url is required"))?;
        let url = Url::parse(&url).map_err(|_| format!("{at}.url is not a URL"))?;
        if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
            return Err(format!("{at}.url must be an http or https URL with a host"));
        }
        if !url.username().is_empty() || url.password().is_some() || url.query().is_some() {
            return Err(format!(
                "{at}.url must not carry credentials or a query; use bearer_token_file"
            ));
        }
        let allow_remote = raw.allow_remote.unwrap_or(false);
        if raw.bearer_token_file.is_some() && !allow_remote {
            return Err(format!(
                "{at}.bearer_token_file is only for a remote endpoint (allow_remote = true)"
            ));
        }
        let interval = raw.interval_seconds.unwrap_or(INTERVAL_DEFAULT);
        if !(10..=3_600).contains(&interval) {
            return Err(format!("{at}.interval_seconds must be between 10 and 3600"));
        }
        let timeout = raw.timeout_seconds.unwrap_or(TIMEOUT_DEFAULT);
        if !(1..=TIMEOUT_MAX).contains(&timeout) || timeout >= interval {
            return Err(format!(
                "{at}.timeout_seconds must be between 1 and {TIMEOUT_MAX} and shorter than the interval"
            ));
        }
        if exporters
            .iter()
            .any(|exporter| exporter.endpoint.url == url)
        {
            return Err(format!("{at}.url {url} is configured twice"));
        }
        exporters.push(Exporter {
            endpoint: Endpoint {
                url,
                allow_remote,
                bearer_token_file: raw.bearer_token_file,
                timeout: Duration::from_secs(timeout),
                max_bytes: MAX_RESPONSE_BYTES,
            },
            interval: Duration::from_secs(interval),
        });
    }
    Ok(exporters)
}

/// The running scrapers of one configuration; dropping them stops every thread.
pub struct Scrapers {
    exporters: Vec<Exporter>,
    stop: Cancellation,
}

impl Scrapers {
    /// Starts one thread per exporter. Each scrapes immediately, then every interval.
    pub fn start(exporters: Vec<Exporter>, sink: Sink, sources: PowerSources) -> Self {
        let configured: Vec<String> = exporters
            .iter()
            .map(|exporter| exporter.source().to_owned())
            .collect();
        // A removed exporter is no longer a source this agent reports.
        sources
            .retain(|source| !source.contains("://") || configured.iter().any(|url| url == source));
        let stop = Cancellation::default();
        for exporter in &exporters {
            let exporter = exporter.clone();
            let stop = stop.clone();
            let sink = sink.clone();
            let sources = sources.clone();
            if let Err(error) = thread::Builder::new()
                .name("exporter".into())
                .spawn(move || run(&exporter, &stop, &sink, &sources))
            {
                warn!(%error, "cannot start an exporter scraper");
            }
        }
        Self { exporters, stop }
    }

    pub fn exporters(&self) -> &[Exporter] {
        &self.exporters
    }
}

impl Drop for Scrapers {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

fn run(exporter: &Exporter, stop: &Cancellation, sink: &Sink, sources: &PowerSources) {
    let mut known = Vec::new();
    while !stop.cancelled() {
        let started = Instant::now();
        let result = text_of(exporter);
        if stop.cancelled() {
            break;
        }
        scrape(exporter, result, Utc::now(), &mut known, sink, sources);
        while !stop.cancelled() && started.elapsed() < exporter.interval {
            thread::sleep(WAIT_SLICE);
        }
    }
}

fn text_of(exporter: &Exporter) -> Result<Vec<Reading>, FetchError> {
    let body = fetch::fetch(&exporter.endpoint)?;
    let samples = text::parse(&body, text::Limits::default(), mapping::wanted)
        .map_err(|error| FetchError::Failed(format!("malformed response: {error}")))?;
    Ok(mapping::map(&samples))
}

/// Queues one scrape's batch. A failed scrape reports every reading the exporter last served as
/// failed, so Renga knows those series are unknown now rather than waiting for them to expire.
fn scrape(
    exporter: &Exporter,
    result: Result<Vec<Reading>, FetchError>,
    now: DateTime<Utc>,
    known: &mut Vec<Reading>,
    sink: &Sink,
    sources: &PowerSources,
) {
    let source = exporter.source();
    let (readings, failed, status) = match result {
        Ok(readings) => {
            let status = if readings.is_empty() {
                "not_present"
            } else {
                "available"
            };
            *known = readings.clone();
            (readings, false, status)
        }
        Err(error) => {
            warn!(exporter = source, %error, "exporter scrape failed");
            let status = match error {
                FetchError::NotPermitted(_) => "not_permitted",
                FetchError::Failed(_) => "unreachable",
            };
            (known.clone(), true, status)
        }
    };
    if sources.status(source) != Some(status) {
        info!(exporter = source, status, "exporter power source status");
    }
    sources.publish(source, status);
    if readings.is_empty() {
        return;
    }
    let batch = batch(&readings, failed, now);
    match serde_json::to_vec(&batch) {
        Ok(body) if body.len() <= MAX_TELEMETRY_BYTES => sink(batch.replay_id, &body),
        Ok(body) => warn!(
            exporter = source,
            bytes = body.len(),
            "exporter batch too large; dropping it"
        ),
        Err(error) => warn!(exporter = source, %error, "cannot encode exporter batch"),
    }
}

/// The host batch for one scrape at `now`; `failed` marks every reading as a failed read.
pub fn batch(readings: &[Reading], failed: bool, now: DateTime<Utc>) -> TelemetryBatch {
    TelemetryBatch::host(
        readings
            .iter()
            .map(|reading| to_sample(reading, failed, now))
            .collect(),
    )
}

fn to_sample(reading: &Reading, failed: bool, now: DateTime<Utc>) -> TelemetrySample {
    let window = chrono::Duration::milliseconds((reading.window_seconds * 1_000.0) as i64);
    let (quantity, unit, value, state) = match reading.measurement {
        Measurement::Watts(watts) => ("real_power", Some("W"), watts, None),
        Measurement::State(state) => ("state", None, None, Some(state)),
    };
    let readable = value.is_some() || state.is_some();
    let status = if failed || !readable {
        "failed"
    } else {
        "valid"
    };
    TelemetrySample {
        target: None,
        sensor: reading.sensor.clone(),
        boundary: reading.boundary.as_str(),
        quantity,
        unit,
        component: reading.supply.clone().map(|name| SampleComponent {
            kind: "power_port",
            name,
        }),
        status,
        origin: "exporter",
        value: if status == "valid" { value } else { None },
        state: if status == "valid" { state } else { None },
        window: SampleWindow {
            start: now - window,
            end: now,
        },
        event_at: now,
        mapping: SampleMapping {
            name: reading.mapping,
            version: mapping::MAPPING_VERSION,
        },
        fresh_for_seconds: FRESH_FOR_SECONDS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::power::hwmon::Boundary;
    use serde_json::{json, Value};
    use std::sync::{Arc, Mutex};

    fn exporter(url: &str) -> Exporter {
        from_raw(vec![RawExporter {
            url: Some(url.into()),
            ..RawExporter::default()
        }])
        .unwrap()
        .remove(0)
    }

    type Batches = Arc<Mutex<Vec<Value>>>;

    fn capture() -> (Sink, Batches) {
        let batches = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&batches);
        let sink: Sink = Arc::new(move |_id, body: &[u8]| {
            captured
                .lock()
                .unwrap()
                .push(serde_json::from_slice(body).unwrap());
        });
        (sink, batches)
    }

    fn dcmi(watts: f64) -> Reading {
        Reading {
            mapping: mapping::IPMI_EXPORTER,
            sensor: "ipmi_exporter/dcmi".into(),
            boundary: Boundary::HostInput,
            supply: None,
            measurement: Measurement::Watts(Some(watts)),
            window_seconds: 0.0,
        }
    }

    #[test]
    fn validates_the_exporter_configuration() {
        let raw = |url: &str| RawExporter {
            url: Some(url.into()),
            ..RawExporter::default()
        };
        let exporter = exporter("http://127.0.0.1:9100/metrics");
        assert_eq!(exporter.interval, Duration::from_secs(60));
        assert_eq!(exporter.endpoint.timeout, Duration::from_secs(10));
        assert!(!exporter.endpoint.allow_remote);

        for (raw, message) in [
            (raw("ftp://127.0.0.1/metrics"), "http or https"),
            (raw("http://user:pass@127.0.0.1/metrics"), "credentials"),
            (raw("http://127.0.0.1/metrics?token=1"), "credentials"),
            (
                RawExporter {
                    bearer_token_file: Some("/etc/renga/token".into()),
                    ..raw("http://127.0.0.1/metrics")
                },
                "remote endpoint",
            ),
            (
                RawExporter {
                    timeout_seconds: Some(60),
                    ..raw("http://127.0.0.1/metrics")
                },
                "timeout_seconds",
            ),
            (RawExporter::default(), "url is required"),
        ] {
            let error = from_raw(vec![raw]).unwrap_err();
            assert!(error.contains(message), "{error}");
        }
        let twice = from_raw(vec![
            raw("http://127.0.0.1:9100/metrics"),
            raw("http://127.0.0.1:9100/metrics"),
        ]);
        assert!(twice.unwrap_err().contains("twice"));
    }

    #[test]
    fn a_scrape_queues_exporter_readings_and_reports_the_source() {
        let exporter = exporter("http://127.0.0.1:9290/metrics");
        let (sink, batches) = capture();
        let sources = PowerSources::default();
        let now = DateTime::parse_from_rfc3339("2026-10-22T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let supply_state = Reading {
            sensor: "ipmi_exporter/sensor/120".into(),
            boundary: Boundary::SupplyInput,
            supply: Some("PSU2".into()),
            measurement: Measurement::State("failed"),
            ..dcmi(0.0)
        };
        let mut known = Vec::new();

        scrape(
            &exporter,
            Ok(vec![dcmi(312.0), supply_state]),
            now,
            &mut known,
            &sink,
            &sources,
        );

        assert_eq!(
            sources.status("http://127.0.0.1:9290/metrics"),
            Some("available")
        );
        let batches = batches.lock().unwrap();
        assert_eq!(
            batches[0]["samples"][0],
            json!({
                "sensor": "ipmi_exporter/dcmi",
                "boundary": "host_input",
                "quantity": "real_power",
                "unit": "W",
                "status": "valid",
                "origin": "exporter",
                "value": 312.0,
                "window": {"start": "2026-10-22T12:00:00Z", "end": "2026-10-22T12:00:00Z"},
                "event_at": "2026-10-22T12:00:00Z",
                "mapping": {"name": "ipmi_exporter", "version": 1},
                "fresh_for_seconds": 300
            })
        );
        assert_eq!(
            batches[0]["samples"][1],
            json!({
                "sensor": "ipmi_exporter/sensor/120",
                "boundary": "supply_input",
                "quantity": "state",
                "component": {"kind": "power_port", "name": "PSU2"},
                "status": "valid",
                "origin": "exporter",
                "state": "failed",
                "window": {"start": "2026-10-22T12:00:00Z", "end": "2026-10-22T12:00:00Z"},
                "event_at": "2026-10-22T12:00:00Z",
                "mapping": {"name": "ipmi_exporter", "version": 1},
                "fresh_for_seconds": 300
            })
        );
    }

    #[test]
    fn a_failed_scrape_reports_known_series_as_failed_never_zero() {
        let exporter = exporter("http://127.0.0.1:9290/metrics");
        let (sink, batches) = capture();
        let sources = PowerSources::default();
        let mut known = Vec::new();

        // Nothing known yet: a failure queues nothing but still reports the source.
        scrape(
            &exporter,
            Err(FetchError::Failed("connection refused".into())),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );
        assert!(batches.lock().unwrap().is_empty());
        assert_eq!(sources.status(exporter.source()), Some("unreachable"));

        scrape(
            &exporter,
            Ok(vec![dcmi(312.0)]),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );
        scrape(
            &exporter,
            Err(FetchError::NotPermitted("403".into())),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );

        let batches = batches.lock().unwrap();
        assert_eq!(batches.len(), 2);
        let failed = &batches[1]["samples"][0];
        assert_eq!(failed["sensor"], "ipmi_exporter/dcmi");
        assert_eq!(failed["status"], "failed");
        assert!(failed.get("value").is_none());
        assert_eq!(sources.status(exporter.source()), Some("not_permitted"));
    }

    #[test]
    fn an_exporter_without_power_metrics_is_not_present() {
        let exporter = exporter("http://127.0.0.1:9100/metrics");
        let (sink, batches) = capture();
        let sources = PowerSources::default();

        scrape(
            &exporter,
            Ok(vec![]),
            Utc::now(),
            &mut Vec::new(),
            &sink,
            &sources,
        );

        assert!(batches.lock().unwrap().is_empty());
        assert_eq!(sources.status(exporter.source()), Some("not_present"));
    }

    #[test]
    fn restarting_forgets_removed_exporters_but_keeps_hwmon() {
        let sources = PowerSources::default();
        sources.publish("hwmon", "available");
        sources.publish("http://127.0.0.1:9100/metrics", "available");
        sources.publish("http://127.0.0.1:9290/metrics", "unreachable");
        let (sink, _batches) = capture();

        let scrapers = Scrapers::start(
            vec![exporter("http://127.0.0.1:9290/metrics")],
            sink,
            sources.clone(),
        );
        drop(scrapers);

        assert_eq!(sources.status("hwmon"), Some("available"));
        assert_eq!(sources.status("http://127.0.0.1:9100/metrics"), None);
        assert!(sources.status("http://127.0.0.1:9290/metrics").is_some());
    }
}

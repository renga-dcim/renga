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
/// Renga keeps sensor names of up to this many characters.
const MAX_SENSOR_CHARS: usize = 255;
/// Check-ins name each exporter by its URL, and Renga rejects a whole check-in whose power
/// source name is longer than this.
const MAX_SOURCE_CHARS: usize = 255;

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

    /// What tells this endpoint's series apart from another endpoint's on the same host: its
    /// host and port, and its path unless it is the usual `/metrics`. Two ipmi_exporters would
    /// otherwise both report `ipmi_exporter/dcmi`, and one's failure would hide the other's
    /// reading.
    fn series_prefix(&self) -> String {
        let url = &self.endpoint.url;
        let host = url.host_str().unwrap_or_default();
        let port = url.port_or_known_default().unwrap_or_default();
        match url.path() {
            "/metrics" => format!("{host}:{port}"),
            path => format!("{host}:{port}{path}"),
        }
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
        if url.as_str().chars().count() > MAX_SOURCE_CHARS {
            return Err(format!(
                "{at}.url must be at most {MAX_SOURCE_CHARS} characters"
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
    Ok(namespaced(exporter, mapping::map(&samples)))
}

/// Puts the endpoint into each reading's sensor, after the mapping's name, so every series
/// belongs to one endpoint.
fn namespaced(exporter: &Exporter, readings: Vec<Reading>) -> Vec<Reading> {
    let prefix = exporter.series_prefix();
    readings
        .into_iter()
        .filter_map(|mut reading| {
            let local = reading
                .sensor
                .strip_prefix(reading.mapping)
                .unwrap_or(&reading.sensor);
            reading.sensor = format!("{}/{prefix}{local}", reading.mapping);
            if reading.sensor.chars().count() > MAX_SENSOR_CHARS {
                warn!(sensor = %reading.sensor, "exporter sensor name is too long to report; skipping it");
                return None;
            }
            Some(reading)
        })
        .collect()
}

/// Queues one scrape's batch. A failed scrape reports every reading the exporter last served as
/// failed, so Renga knows those series are unknown now rather than waiting for them to expire.
/// So does a successful scrape for a series it no longer serves: ipmi_exporter drops the DCMI
/// reading when its DCMI collector fails, and still answers 200.
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
            let gone: Vec<Reading> = known
                .iter()
                .filter(|old| !readings.iter().any(|new| series(new) == series(old)))
                .map(|old| Reading {
                    measurement: old.measurement.unreadable(),
                    ..old.clone()
                })
                .collect();
            *known = readings.clone();
            (readings.into_iter().chain(gone).collect(), false, status)
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

/// What Renga keys a current reading by: a sensor's average over one window, its average over
/// another, and its instantaneous value are different series.
fn series(reading: &Reading) -> (&str, &'static str, &'static str, i64) {
    (
        &reading.sensor,
        reading.boundary.as_str(),
        reading.measurement.quantity(),
        window_ms(reading),
    )
}

fn window_ms(reading: &Reading) -> i64 {
    // The mapping bounds windows to a day, so this cannot overflow.
    (reading.window_seconds * 1_000.0) as i64
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
    let window = chrono::Duration::milliseconds(window_ms(reading));
    let quantity = reading.measurement.quantity();
    let (unit, value, state) = match reading.measurement {
        Measurement::Watts(watts) => (Some("W"), watts, None),
        Measurement::State(state) => (None, None, state),
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
        leg: None,
        coverage: None,
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
        let default = exporter("http://127.0.0.1:9100/metrics");
        assert_eq!(default.interval, Duration::from_secs(60));
        assert_eq!(default.endpoint.timeout, Duration::from_secs(10));
        assert!(!default.endpoint.allow_remote);

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
            (
                raw(&format!("http://127.0.0.1:9100/{}", "p".repeat(234))),
                "at most 255 characters",
            ),
        ] {
            let error = from_raw(vec![raw]).unwrap_err();
            assert!(error.contains(message), "{error}");
        }
        // The longest URL a check-in can name is accepted.
        let longest = format!("http://127.0.0.1:9100/{}", "p".repeat(233));
        assert_eq!(longest.len(), 255);
        assert_eq!(exporter(&longest).source(), longest);
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
            measurement: Measurement::State(Some("failed")),
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
    fn a_series_an_exporter_stops_serving_is_failed_not_kept() {
        let exporter = exporter("http://127.0.0.1:9290/metrics");
        let (sink, batches) = capture();
        let sources = PowerSources::default();
        let supply = Reading {
            sensor: "ipmi_exporter/sensor/98".into(),
            boundary: Boundary::SupplyInput,
            supply: Some("PSU1".into()),
            ..dcmi(151.0)
        };
        let mut known = Vec::new();

        scrape(
            &exporter,
            Ok(vec![dcmi(312.0), supply.clone()]),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );
        // ipmi_exporter's DCMI collector failed: it answers 200 without the reading.
        scrape(
            &exporter,
            Ok(vec![supply]),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );
        // Then the exporter goes away.
        scrape(
            &exporter,
            Err(FetchError::Failed("connection refused".into())),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );

        let batches = batches.lock().unwrap();
        let summary = |batch: &Value| -> Vec<(String, String)> {
            batch["samples"]
                .as_array()
                .unwrap()
                .iter()
                .map(|sample| {
                    (
                        sample["sensor"].as_str().unwrap().to_owned(),
                        sample["status"].as_str().unwrap().to_owned(),
                    )
                })
                .collect()
        };
        let pair = |sensor: &str, status: &str| (sensor.to_owned(), status.to_owned());
        assert_eq!(
            summary(&batches[1]),
            [
                pair("ipmi_exporter/sensor/98", "valid"),
                pair("ipmi_exporter/dcmi", "failed")
            ]
        );
        assert!(batches[1]["samples"][1].get("value").is_none());
        assert_eq!(
            summary(&batches[2]),
            [pair("ipmi_exporter/sensor/98", "failed")]
        );
    }

    #[test]
    fn a_series_whose_window_changes_fails_its_old_window() {
        let exporter = exporter("http://127.0.0.1:9100/metrics");
        let (sink, batches) = capture();
        let sources = PowerSources::default();
        let average = |watts, window_seconds| Reading {
            mapping: mapping::NODE_EXPORTER,
            sensor: "node_exporter/127.0.0.1:9100/hwmon/power1".into(),
            boundary: Boundary::SupplyInput,
            measurement: Measurement::Watts(watts),
            window_seconds,
            ..dcmi(0.0)
        };
        let mut known = Vec::new();

        scrape(
            &exporter,
            Ok(vec![average(Some(245.0), 1.0)]),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );
        // The average's interval went missing, so the mapping fails it with no window: a new
        // series. The 1-second series must not stay current until it expires.
        scrape(
            &exporter,
            Ok(vec![average(None, 0.0)]),
            Utc::now(),
            &mut known,
            &sink,
            &sources,
        );

        let batches = batches.lock().unwrap();
        let windows: Vec<(String, i64)> = batches[1]["samples"]
            .as_array()
            .unwrap()
            .iter()
            .map(|sample| {
                let start =
                    DateTime::parse_from_rfc3339(sample["window"]["start"].as_str().unwrap());
                let end = DateTime::parse_from_rfc3339(sample["window"]["end"].as_str().unwrap());
                (
                    sample["status"].as_str().unwrap().to_owned(),
                    (end.unwrap() - start.unwrap()).num_milliseconds(),
                )
            })
            .collect();
        assert_eq!(
            windows,
            [("failed".to_owned(), 0), ("failed".to_owned(), 1_000)]
        );
    }

    #[test]
    fn each_endpoint_reports_its_own_series() {
        let mapped = || vec![dcmi(312.0)];
        let sensors = |url: &str| -> Vec<String> {
            namespaced(&exporter(url), mapped())
                .into_iter()
                .map(|reading| reading.sensor)
                .collect()
        };
        assert_eq!(
            sensors("http://127.0.0.1:9290/metrics"),
            ["ipmi_exporter/127.0.0.1:9290/dcmi"]
        );
        assert_eq!(
            sensors("http://127.0.0.1:9291/metrics"),
            ["ipmi_exporter/127.0.0.1:9291/dcmi"]
        );
        assert_eq!(
            sensors("http://localhost/ipmi/metrics"),
            ["ipmi_exporter/localhost:80/ipmi/metrics/dcmi"]
        );
        // The longest URL still makes a sensor name too long to report.
        let long = format!("http://127.0.0.1:9290/{}", "p".repeat(233));
        assert!(sensors(&long).is_empty());
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

//! Power sensors under `/sys/class/hwmon` (RFD 10, "Host agent").
//!
//! The files are world-readable, so this source works inside the agent's sandbox. Only drivers
//! whose readings are known to measure a power boundary are mapped: `acpi_power_meter` reports
//! the host's input power, and a short list of power supply drivers label their input and output
//! power. A regulator or GPU also reports watts, but for one component rather than the host, so
//! anything else is left unmapped rather than guessed at.

use std::{
    fs, io,
    path::{Path, PathBuf},
    time::Duration,
};

/// The mapping every hwmon reading names, so Renga can tell which rules produced it.
pub const MAPPING: &str = "hwmon";
pub const MAPPING_VERSION: u32 = 1;

pub const ROOT: &str = "/sys/class/hwmon";

/// Power supply drivers whose `pin`/`pout` labels are the supply's own input and output.
const SUPPLY_DRIVERS: &[&str] = &[
    "bel-pfe",
    "dps920ab",
    "fsp-3y",
    "ibm-cffps",
    "inspur-ipsps1",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Boundary {
    HostInput,
    SupplyInput,
    SupplyOutput,
}

impl Boundary {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HostInput => "host_input",
            Self::SupplyInput => "supply_input",
            Self::SupplyOutput => "supply_output",
        }
    }
}

/// One mapped sensor's reading.
#[derive(Debug, Clone, PartialEq)]
pub struct Reading {
    /// Stable across reboots: the driver, its device, and the sensor, never the `hwmonN` index.
    pub sensor: String,
    pub boundary: Boundary,
    /// Watts, or why the sensor could not be read. A failed read is reported as a failure,
    /// never as zero.
    pub watts: Result<f64, SensorError>,
    /// The period an averaged sensor covers; zero for an instantaneous one.
    pub window: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SensorError {
    pub message: String,
    /// The sandbox or file permissions refused the read.
    pub denied: bool,
}

/// Whether the host has any mapped power sensor this process can read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Availability {
    Available,
    NotPermitted,
    NotPresent,
}

impl Availability {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::NotPermitted => "not_permitted",
            Self::NotPresent => "not_present",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Scan {
    pub readings: Vec<Reading>,
    pub availability: Availability,
}

/// Reads every mapped power sensor under `root`.
pub fn scan(root: &Path) -> Scan {
    let mut chips: Vec<PathBuf> = match fs::read_dir(root) {
        Ok(listing) => listing.flatten().map(|item| item.path()).collect(),
        Err(error) => {
            return Scan {
                readings: Vec::new(),
                availability: unreadable(&error),
            }
        }
    };
    chips.sort();

    let mut readings = Vec::new();
    let mut denied = false;
    for chip in chips {
        let name = match read_trimmed(&chip.join("name")) {
            Ok(name) => name,
            Err(error) => {
                denied |= error.kind() == io::ErrorKind::PermissionDenied;
                continue;
            }
        };
        readings.extend(chip_readings(&chip, &name));
    }
    let availability = if readings.iter().any(|reading| reading.watts.is_ok()) {
        Availability::Available
    } else if denied
        || readings
            .iter()
            .any(|reading| reading.watts.as_ref().is_err_and(|error| error.denied))
    {
        Availability::NotPermitted
    } else {
        Availability::NotPresent
    };
    Scan {
        readings,
        availability,
    }
}

fn unreadable(error: &io::Error) -> Availability {
    if error.kind() == io::ErrorKind::PermissionDenied {
        Availability::NotPermitted
    } else {
        Availability::NotPresent
    }
}

fn chip_readings(chip: &Path, name: &str) -> Vec<Reading> {
    let device = fs::read_link(chip.join("device"))
        .ok()
        .and_then(|target| {
            target
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .or_else(|| {
            chip.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_default();

    let mut channels: Vec<u32> = fs::read_dir(chip)
        .map(|listing| {
            listing
                .flatten()
                .filter_map(|item| channel(&item.file_name().to_string_lossy()))
                .collect()
        })
        .unwrap_or_default();
    channels.sort_unstable();
    channels.dedup();

    channels
        .into_iter()
        .filter_map(|number| {
            let prefix = format!("power{number}");
            let boundary = boundary(
                name,
                read_trimmed(&chip.join(format!("{prefix}_label"))).ok(),
            )?;
            Some(reading(
                chip,
                &prefix,
                format!("{name}/{device}/{prefix}"),
                boundary,
            ))
        })
        .collect()
}

/// The channel number of a `powerN_input` or `powerN_average` file.
fn channel(file: &str) -> Option<u32> {
    let rest = file.strip_prefix("power")?;
    let (number, kind) = rest.split_once('_')?;
    matches!(kind, "input" | "average")
        .then(|| number.parse().ok())
        .flatten()
}

fn boundary(driver: &str, label: Option<String>) -> Option<Boundary> {
    if driver == "acpi_power_meter" {
        return Some(Boundary::HostInput);
    }
    if !SUPPLY_DRIVERS.contains(&driver) {
        return None;
    }
    let label = label?.to_ascii_lowercase();
    if label.starts_with("pin") {
        Some(Boundary::SupplyInput)
    } else if label.starts_with("pout") {
        Some(Boundary::SupplyOutput)
    } else {
        None
    }
}

/// Prefers the averaged value, which smooths a load's swings over the driver's interval.
fn reading(chip: &Path, prefix: &str, sensor: String, boundary: Boundary) -> Reading {
    let average = chip.join(format!("{prefix}_average"));
    let (file, window) = if average.exists() {
        let interval = read_trimmed(&chip.join(format!("{prefix}_average_interval")))
            .ok()
            .and_then(|milliseconds| milliseconds.parse().ok())
            .map(Duration::from_millis)
            .unwrap_or_default();
        (average, interval)
    } else {
        (chip.join(format!("{prefix}_input")), Duration::ZERO)
    };
    let watts = read_trimmed(&file)
        .map_err(|error| SensorError {
            message: format!("cannot read {}: {error}", file.display()),
            denied: error.kind() == io::ErrorKind::PermissionDenied,
        })
        .and_then(|microwatts| {
            microwatts
                .parse::<u64>()
                .map(|microwatts| microwatts as f64 / 1_000_000.0)
                .map_err(|_| SensorError {
                    message: format!("{} is not a power reading: {microwatts:?}", file.display()),
                    denied: false,
                })
        });
    Reading {
        sensor,
        boundary,
        watts,
        window,
    }
}

fn read_trimmed(path: &Path) -> io::Result<String> {
    fs::read_to_string(path).map(|value| value.trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    struct Root(PathBuf);

    impl Root {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("renga-hwmon-{}", Uuid::new_v4()));
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }

        fn chip(&self, index: u32, name: &str, files: &[(&str, &str)]) -> PathBuf {
            let chip = self.0.join(format!("hwmon{index}"));
            fs::create_dir_all(&chip).unwrap();
            fs::write(chip.join("name"), format!("{name}\n")).unwrap();
            for (file, value) in files {
                fs::write(chip.join(file), format!("{value}\n")).unwrap();
            }
            chip
        }
    }

    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn maps_the_acpi_power_meter_as_host_input() {
        let root = Root::new();
        let chip = root.chip(
            3,
            "acpi_power_meter",
            &[
                ("power1_average", "245000000"),
                ("power1_average_interval", "1000"),
            ],
        );
        #[cfg(unix)]
        std::os::unix::fs::symlink("../../devices/LNXSYSTM:00/ACPI000D:00", chip.join("device"))
            .unwrap();

        let scan = scan(&root.0);

        assert_eq!(scan.availability, Availability::Available);
        assert_eq!(
            scan.readings,
            [Reading {
                sensor: if cfg!(unix) {
                    "acpi_power_meter/ACPI000D:00/power1".into()
                } else {
                    "acpi_power_meter/hwmon3/power1".into()
                },
                boundary: Boundary::HostInput,
                watts: Ok(245.0),
                window: Duration::from_secs(1),
            }]
        );
    }

    #[test]
    fn maps_supply_input_and_output_by_label_on_known_supply_drivers() {
        let root = Root::new();
        root.chip(
            0,
            "ibm-cffps",
            &[
                ("power1_input", "512250000"),
                ("power1_label", "pin"),
                ("power2_input", "480000000"),
                ("power2_label", "pout1"),
                ("power3_input", "1"),
                ("power3_label", "vmon"),
            ],
        );

        let readings = scan(&root.0).readings;

        assert_eq!(
            readings
                .iter()
                .map(|reading| (
                    reading.sensor.as_str(),
                    reading.boundary,
                    reading.watts.clone().unwrap()
                ))
                .collect::<Vec<_>>(),
            [
                ("ibm-cffps/hwmon0/power1", Boundary::SupplyInput, 512.25),
                ("ibm-cffps/hwmon0/power2", Boundary::SupplyOutput, 480.0),
            ]
        );
        assert!(readings.iter().all(|reading| reading.window.is_zero()));
    }

    #[test]
    fn leaves_component_sensors_unmapped() {
        let root = Root::new();
        // A GPU's and a voltage regulator's watts are not the host's or a supply's.
        root.chip(
            0,
            "amdgpu",
            &[("power1_average", "90000000"), ("power1_label", "PPT")],
        );
        root.chip(
            1,
            "isl68137",
            &[("power1_input", "150000000"), ("power1_label", "pin")],
        );
        root.chip(2, "coretemp", &[("temp1_input", "40000")]);

        let scan = scan(&root.0);

        assert!(scan.readings.is_empty());
        assert_eq!(scan.availability, Availability::NotPresent);
    }

    #[test]
    fn a_sensor_that_cannot_be_read_is_a_failure_not_zero() {
        let root = Root::new();
        root.chip(0, "acpi_power_meter", &[("power1_average", "garbage")]);
        root.chip(1, "acpi_power_meter", &[("power1_input", "")]);

        let scan = scan(&root.0);

        assert_eq!(scan.readings.len(), 2);
        assert!(scan.readings.iter().all(|reading| reading.watts.is_err()));
        assert_eq!(scan.availability, Availability::NotPresent);
    }

    #[test]
    fn a_missing_root_has_nothing_present() {
        let root = Root::new();
        let scan = scan(&root.0.join("absent"));
        assert_eq!(
            scan,
            Scan {
                readings: Vec::new(),
                availability: Availability::NotPresent
            }
        );
    }

    #[test]
    fn channels_come_from_input_and_average_files_only() {
        assert_eq!(channel("power1_input"), Some(1));
        assert_eq!(channel("power12_average"), Some(12));
        assert_eq!(channel("power1_label"), None);
        assert_eq!(channel("power1_average_interval"), None);
        assert_eq!(channel("powerx_input"), None);
        assert_eq!(channel("temp1_input"), None);
    }
}

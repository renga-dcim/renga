//! Power sensors under `/sys/class/hwmon` (RFD 10, "Host agent").
//!
//! The files are world-readable, so this source works inside the agent's sandbox. Only drivers
//! whose readings are known to measure a power boundary are mapped: a short list of power supply
//! drivers label their input and output power. A regulator or GPU also reports watts, but for
//! one component rather than the host, so anything else is left unmapped rather than guessed at.
//!
//! That includes the ACPI power meter (`ACPI000D`). Firmware says whether it measures input or
//! output power (`_PMC`) and which devices it covers (`_PMD`), but Linux does not expose the
//! direction, so its watts may be what supplies deliver rather than what the host draws. The
//! host's input power comes from a source that says what it measures, such as the BMC.
//!
//! Drivers are recognized by what sysfs shows, not by module name. Most drivers put `name` and
//! their sensor files on the hwmon device; older ones put them on its parent device instead, so
//! both directories are looked at, as node_exporter and lm-sensors do. A PMBus supply's `name`
//! is its I2C client name: the `i2c_device_id`, or the devicetree compatible without its vendor
//! prefix, with `-` turned into `_`.
//!
//! A sensor's identity must survive reboots, so it is built from the device's firmware node
//! (its devicetree node path or ACPI namespace path, such as `\_SB_.PCI0.I2C9.PSU0`), never
//! from the `hwmonN` index, an I2C bus number, or a sysfs name such as `PSU0000:00`, which the
//! kernel may number differently on the next boot. A chip without a firmware node is not reported: a
//! series that could silently swap supplies is worse than none.

use std::{
    fs, io,
    path::{Path, PathBuf},
    time::Duration,
};
use tracing::warn;

/// The mapping every hwmon reading names, so Renga can tell which rules produced it.
pub const MAPPING: &str = "hwmon";
pub const MAPPING_VERSION: u32 = 1;

pub const ROOT: &str = "/sys/class/hwmon";

/// The ACPI power meter's `name`, which it shows on its ACPI device rather than its hwmon
/// device. Its readings are left unmapped; see the module documentation.
pub const POWER_METER: &str = "power_meter";

/// The hwmon names of power supplies whose `pin`/`pout` labels are the supply's own input and
/// output: `ibm-cffps` (`ibm_cffps1`, `ibm_cffps2`, or `cffps1`/`cffps2` from devicetree or
/// detection), `fsp-3y`, `bel-pfe`, `inspur-ipsps`, and `dps920ab`.
const SUPPLY_NAMES: &[&str] = &[
    "cffps1",
    "cffps2",
    "dps920ab",
    "ibm_cffps1",
    "ibm_cffps2",
    "ipsps1",
    "pfe1100",
    "pfe3000",
    "yh5151e",
    "ym2151e",
];

/// The longest averaging interval a sample may declare, which Renga accepts as a window.
const MAX_INTERVAL_MS: u64 = 86_400_000;
/// Renga keeps sensor names of up to this many characters.
const MAX_SENSOR_CHARS: usize = 255;

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
    /// Stable across reboots: the driver, its device's firmware node, and the sensor, never the
    /// `hwmonN` index or an I2C bus number.
    pub sensor: String,
    pub boundary: Boundary,
    /// Watts, or why the sensor could not be read. A failed read is reported as a failure,
    /// never as zero.
    pub watts: Result<f64, SensorError>,
    /// The period an averaged sensor covers; zero for an instantaneous one, and for an average
    /// whose period is unknown, which is then a failed reading.
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
        match chip_readings(&chip) {
            Ok(chip_readings) => readings.extend(chip_readings),
            Err(error) => denied |= error.kind() == io::ErrorKind::PermissionDenied,
        }
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

/// The mapped readings of one chip. A permission error on anything needed to find or name its
/// sensors is returned, so a sandbox that hides them reads as not permitted, not as absent.
fn chip_readings(chip: &Path) -> io::Result<Vec<Reading>> {
    let Some((attributes, name)) = attributes(chip)? else {
        return Ok(Vec::new());
    };
    if !SUPPLY_NAMES.contains(&name.as_str()) {
        return Ok(Vec::new());
    }
    let Some(device) = firmware_node(chip)? else {
        warn!(chip = %chip.display(), driver = %name, "power sensor has no firmware node; skipping it");
        return Ok(Vec::new());
    };

    let mut channels: Vec<u32> = fs::read_dir(&attributes)?
        .flatten()
        .filter_map(|item| channel(&item.file_name().to_string_lossy()))
        .collect();
    channels.sort_unstable();
    channels.dedup();

    let mut readings = Vec::new();
    for number in channels {
        let prefix = format!("power{number}");
        let label = match read_trimmed(&attributes.join(format!("{prefix}_label"))) {
            Ok(label) => Some(label),
            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => return Err(error),
            Err(_) => None,
        };
        let Some(boundary) = boundary(&name, label) else {
            continue;
        };
        let sensor = format!("{name}/{device}/{prefix}");
        if sensor.chars().count() > MAX_SENSOR_CHARS {
            warn!(%sensor, "power sensor name is too long to report; skipping it");
            continue;
        }
        readings.push(reading(&attributes, &prefix, sensor, boundary));
    }
    Ok(readings)
}

/// The directory holding the chip's `name` and sensor files, and that name: the hwmon device's
/// own, or else its parent device's, where older drivers put them.
fn attributes(chip: &Path) -> io::Result<Option<(PathBuf, String)>> {
    for dir in [chip.to_path_buf(), chip.join("device")] {
        if let Some(name) = optional(read_trimmed(&dir.join("name")))? {
            return Ok(Some((dir, name)));
        }
    }
    Ok(None)
}

/// Where firmware describes the chip's device, which stays the same across reboots: its
/// devicetree node, or its ACPI namespace path, whether the device is an ACPI device itself or
/// one that ACPI enumerated. A permission error is returned rather than read as no node.
fn firmware_node(chip: &Path) -> io::Result<Option<String>> {
    let device = chip.join("device");
    if let Some(node) = optional(fs::canonicalize(device.join("of_node")))? {
        let node = node.to_string_lossy();
        if let Some((_, path)) = node.split_once("/devicetree/base/") {
            if !path.is_empty() {
                return Ok(Some(format!("dt:{path}")));
            }
        }
    }
    for file in [
        device.join("firmware_node").join("path"),
        device.join("path"),
    ] {
        if let Some(path) = optional(read_trimmed(&file))? {
            if !path.is_empty() {
                return Ok(Some(format!("acpi:{path}")));
            }
        }
    }
    Ok(None)
}

/// A missing file as `None`, keeping permission errors.
fn optional<T>(result: io::Result<T>) -> io::Result<Option<T>> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => Err(error),
        Err(_) => Ok(None),
    }
}

/// The channel number of a `powerN_input` or `powerN_average` file.
fn channel(file: &str) -> Option<u32> {
    let rest = file.strip_prefix("power")?;
    let (number, kind) = rest.split_once('_')?;
    matches!(kind, "input" | "average")
        .then(|| number.parse().ok())
        .flatten()
}

/// The boundary a sensor of `driver` measures, by its label for a supply.
pub fn boundary(driver: &str, label: Option<String>) -> Option<Boundary> {
    if !SUPPLY_NAMES.contains(&driver) {
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

/// Prefers the averaged value, which smooths a load's swings over the driver's interval. An
/// average whose interval cannot be known is a failed reading, never an instantaneous one.
fn reading(attributes: &Path, prefix: &str, sensor: String, boundary: Boundary) -> Reading {
    let average = attributes.join(format!("{prefix}_average"));
    let (file, window) = if average.exists() {
        match interval(&attributes.join(format!("{prefix}_average_interval"))) {
            Ok(window) => (average, window),
            Err(error) => {
                return Reading {
                    sensor,
                    boundary,
                    watts: Err(error),
                    window: Duration::ZERO,
                }
            }
        }
    } else {
        (attributes.join(format!("{prefix}_input")), Duration::ZERO)
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

/// An averaging interval in milliseconds, from 1 ms to a day.
fn interval(file: &Path) -> Result<Duration, SensorError> {
    let milliseconds = read_trimmed(file).map_err(|error| SensorError {
        message: format!("cannot read {}: {error}", file.display()),
        denied: error.kind() == io::ErrorKind::PermissionDenied,
    })?;
    match milliseconds.parse::<u64>() {
        Ok(milliseconds) if (1..=MAX_INTERVAL_MS).contains(&milliseconds) => {
            Ok(Duration::from_millis(milliseconds))
        }
        _ => Err(SensorError {
            message: format!(
                "{} is not an averaging interval from 1 to {MAX_INTERVAL_MS} ms: {milliseconds:?}",
                file.display()
            ),
            denied: false,
        }),
    }
}

fn read_trimmed(path: &Path) -> io::Result<String> {
    fs::read_to_string(path).map(|value| value.trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use uuid::Uuid;

    /// A fake `/sys`: hwmon chips under `class/hwmon`, linked to devices under `devices` that
    /// may point at a devicetree node or an ACPI node.
    struct Sys(PathBuf);

    enum Device<'a> {
        /// An ACPI device under `devices/`, with its ACPI namespace `path`.
        Acpi { path: &'a str, namespace: &'a str },
        /// An I2C device described by a devicetree node, under `firmware/devicetree/base/`.
        Dt { path: &'a str, node: &'a str },
        /// An I2C device ACPI enumerated: its `firmware_node` is an ACPI device at `node`.
        AcpiI2c {
            path: &'a str,
            node: &'a str,
            namespace: &'a str,
        },
        /// An I2C device instantiated from user space, with no firmware node.
        Bare { path: &'a str },
    }

    impl Sys {
        fn new() -> Self {
            let sys = std::env::temp_dir().join(format!("renga-hwmon-{}", Uuid::new_v4()));
            fs::create_dir_all(sys.join("class/hwmon")).unwrap();
            Self(sys)
        }

        fn root(&self) -> PathBuf {
            self.0.join("class/hwmon")
        }

        /// A chip whose `name` and sensor files are on its hwmon device.
        fn chip(&self, index: u32, name: Option<&str>, device: Device, files: &[(&str, &str)]) {
            let chip = self.root().join(format!("hwmon{index}"));
            fs::create_dir_all(&chip).unwrap();
            write(&chip, name, files);
            symlink(self.device(device), chip.join("device")).unwrap();
        }

        /// An ACPI power meter as Linux registers it: `name` and the sensor files are on the
        /// ACPI device, and its hwmon device only links to it.
        fn meter(&self, index: u32, path: &str, namespace: &str, files: &[(&str, &str)]) {
            let chip = self.root().join(format!("hwmon{index}"));
            fs::create_dir_all(&chip).unwrap();
            let device = self.device(Device::Acpi { path, namespace });
            write(&device, Some(POWER_METER), files);
            symlink(device, chip.join("device")).unwrap();
        }

        fn device(&self, device: Device) -> PathBuf {
            let dir = |relative: &str| {
                let path = self.0.join(relative);
                fs::create_dir_all(&path).unwrap();
                path
            };
            match device {
                Device::Acpi { path, namespace } => {
                    let device = dir(&format!("devices/{path}"));
                    fs::write(device.join("path"), format!("{namespace}\n")).unwrap();
                    device
                }
                Device::Dt { path, node } => {
                    let device = dir(&format!("devices/{path}"));
                    symlink(
                        dir(&format!("firmware/devicetree/base/{node}")),
                        device.join("of_node"),
                    )
                    .unwrap();
                    device
                }
                Device::AcpiI2c {
                    path,
                    node,
                    namespace,
                } => {
                    let device = dir(&format!("devices/{path}"));
                    let node = dir(&format!("devices/{node}"));
                    fs::write(node.join("path"), format!("{namespace}\n")).unwrap();
                    symlink(node, device.join("firmware_node")).unwrap();
                    device
                }
                Device::Bare { path } => dir(&format!("devices/{path}")),
            }
        }
    }

    fn write(dir: &Path, name: Option<&str>, files: &[(&str, &str)]) {
        if let Some(name) = name {
            fs::write(dir.join("name"), format!("{name}\n")).unwrap();
        }
        for (file, value) in files {
            fs::write(dir.join(file), format!("{value}\n")).unwrap();
        }
    }

    impl Drop for Sys {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const METER_PATH: &str = "LNXSYSTM:00/LNXSYBUS:00/ACPI000D:00";
    const METER_NAMESPACE: &str = "\\_SB_.PMI0";
    const PSU0: &str = "\\_SB_.PCI0.I2C9.PSU0";
    const PSU1: &str = "\\_SB_.PCI0.I2C9.PSU1";

    fn sensors(scan: &Scan) -> Vec<(&str, Boundary)> {
        scan.readings
            .iter()
            .map(|reading| (reading.sensor.as_str(), reading.boundary))
            .collect()
    }

    #[test]
    fn leaves_the_acpi_power_meter_unmapped() {
        // Readable, with a usable interval, but nothing says whether it measures input or output.
        let sys = Sys::new();
        sys.meter(
            3,
            METER_PATH,
            METER_NAMESPACE,
            &[
                ("power1_average", "245000000"),
                ("power1_average_interval", "1000"),
            ],
        );

        let scan = scan(&sys.root());

        assert!(scan.readings.is_empty());
        assert_eq!(scan.availability, Availability::NotPresent);
    }

    /// A supply that ACPI enumerated on I2C, named in the ACPI namespace.
    fn acpi_supply(sys: &Sys, index: u32, instance: &str, namespace: &str, files: &[(&str, &str)]) {
        let mut files = files.to_vec();
        files.push(("power1_label", "pin"));
        sys.chip(
            index,
            Some("pfe3000"),
            Device::AcpiI2c {
                path: &format!("pci0000:00/i2c-9/9-00{index}0"),
                node: &format!("LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/PSU0000:{instance}"),
                namespace,
            },
            &files,
        );
    }

    #[test]
    fn recognizes_every_supply_by_the_name_sysfs_shows() {
        let sys = Sys::new();
        for (index, name) in SUPPLY_NAMES.iter().enumerate() {
            let path = format!("platform/i2c-3/3-00{index:02}");
            let node = format!("i2c@1e78a000/psu@{index}");
            sys.chip(
                index as u32,
                Some(name),
                Device::Dt {
                    path: &path,
                    node: &node,
                },
                &[("power1_input", "512250000"), ("power1_label", "pin")],
            );
        }
        // Module names are not what sysfs shows.
        for (index, name) in [
            "ibm-cffps",
            "fsp-3y",
            "bel-pfe",
            "inspur-ipsps1",
            "acpi_power_meter",
        ]
        .iter()
        .enumerate()
        {
            let index = index + 20;
            let path = format!("platform/i2c-3/3-00{index}");
            let node = format!("i2c@1e78a000/other@{index}");
            sys.chip(
                index as u32,
                Some(name),
                Device::Dt {
                    path: &path,
                    node: &node,
                },
                &[("power1_input", "1"), ("power1_label", "pin")],
            );
        }

        let scan = scan(&sys.root());

        let mut found: Vec<&str> = scan
            .readings
            .iter()
            .map(|reading| reading.sensor.split('/').next().unwrap())
            .collect();
        found.sort_unstable();
        assert_eq!(found, SUPPLY_NAMES);
        assert!(scan.readings.iter().all(
            |reading| reading.boundary == Boundary::SupplyInput && reading.watts == Ok(512.25)
        ));
    }

    #[test]
    fn maps_supply_input_and_output_by_label() {
        let sys = Sys::new();
        sys.chip(
            0,
            Some("ibm_cffps1"),
            Device::Dt {
                path: "platform/i2c-3/3-0068",
                node: "i2c@1e78a400/power-supply@68",
            },
            &[
                ("power1_input", "512250000"),
                ("power1_label", "pin"),
                ("power2_input", "480000000"),
                ("power2_label", "pout1"),
                ("power3_input", "1"),
                ("power3_label", "vmon"),
            ],
        );

        let scan = scan(&sys.root());

        assert_eq!(
            sensors(&scan),
            [
                (
                    "ibm_cffps1/dt:i2c@1e78a400/power-supply@68/power1",
                    Boundary::SupplyInput
                ),
                (
                    "ibm_cffps1/dt:i2c@1e78a400/power-supply@68/power2",
                    Boundary::SupplyOutput
                ),
            ]
        );
        assert!(scan.readings.iter().all(|reading| reading.window.is_zero()));
    }

    #[test]
    fn identity_follows_the_firmware_node_not_hwmon_or_i2c_numbering() {
        let first = Sys::new();
        first.chip(
            0,
            Some("dps920ab"),
            Device::Dt {
                path: "platform/i2c-7/7-0058",
                node: "i2c-mux/i2c@1/psu@58",
            },
            &[("power1_input", "100000000"), ("power1_label", "pin")],
        );
        first.chip(
            1,
            Some("dps920ab"),
            Device::Dt {
                path: "platform/i2c-8/8-0058",
                node: "i2c-mux/i2c@2/psu@58",
            },
            &[("power1_input", "200000000"), ("power1_label", "pin")],
        );
        // The next boot numbers the hwmon devices and mux buses the other way round.
        let second = Sys::new();
        second.chip(
            4,
            Some("dps920ab"),
            Device::Dt {
                path: "platform/i2c-8/8-0058",
                node: "i2c-mux/i2c@1/psu@58",
            },
            &[("power1_input", "100000000"), ("power1_label", "pin")],
        );
        second.chip(
            2,
            Some("dps920ab"),
            Device::Dt {
                path: "platform/i2c-7/7-0058",
                node: "i2c-mux/i2c@2/psu@58",
            },
            &[("power1_input", "200000000"), ("power1_label", "pin")],
        );

        let by_sensor = |sys: &Sys| {
            let mut readings: Vec<(String, f64)> = scan(&sys.root())
                .readings
                .into_iter()
                .map(|reading| (reading.sensor, reading.watts.unwrap()))
                .collect();
            readings.sort_by(|a, b| a.0.cmp(&b.0));
            readings
        };
        assert_eq!(by_sensor(&first), by_sensor(&second));
        assert_eq!(
            by_sensor(&first)[0].0,
            "dps920ab/dt:i2c-mux/i2c@1/psu@58/power1"
        );

        // ACPI-enumerated I2C supplies use their ACPI path.
        let acpi = Sys::new();
        acpi.chip(
            0,
            Some("pfe3000"),
            Device::AcpiI2c {
                path: "pci0000:00/i2c-9/9-0010",
                node: "LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/PSU0000:00",
                namespace: "\\_SB_.PCI0.I2C9.PSU0",
            },
            &[("power1_input", "1000000"), ("power1_label", "pin")],
        );
        assert_eq!(
            sensors(&scan(&acpi.root())),
            [(
                "pfe3000/acpi:\\_SB_.PCI0.I2C9.PSU0/power1",
                Boundary::SupplyInput
            )]
        );
    }

    #[test]
    fn acpi_identity_follows_the_namespace_not_sysfs_instance_numbers() {
        let supplies = |order: [(&str, &str); 2]| {
            let sys = Sys::new();
            for (index, (instance, namespace)) in order.into_iter().enumerate() {
                let watts = if namespace.ends_with('0') {
                    "100000000"
                } else {
                    "200000000"
                };
                acpi_supply(
                    &sys,
                    index as u32,
                    instance,
                    namespace,
                    &[("power1_input", watts)],
                );
            }
            let mut readings: Vec<(String, f64)> = scan(&sys.root())
                .readings
                .into_iter()
                .map(|reading| (reading.sensor, reading.watts.unwrap()))
                .collect();
            readings.sort_by(|a, b| a.0.cmp(&b.0));
            readings
        };
        // The next boot numbers the two supplies' ACPI devices the other way round.
        let first = supplies([("00", PSU0), ("01", PSU1)]);
        let second = supplies([("01", PSU0), ("00", PSU1)]);
        assert_eq!(first, second);
        assert_eq!(
            first,
            [
                (
                    "pfe3000/acpi:\\_SB_.PCI0.I2C9.PSU0/power1".to_owned(),
                    100.0
                ),
                (
                    "pfe3000/acpi:\\_SB_.PCI0.I2C9.PSU1/power1".to_owned(),
                    200.0
                ),
            ]
        );
    }

    #[test]
    fn a_supply_without_a_firmware_node_is_not_reported() {
        let sys = Sys::new();
        sys.chip(
            0,
            Some("ipsps1"),
            Device::Bare {
                path: "platform/i2c-3/3-0058",
            },
            &[("power1_input", "1000000"), ("power1_label", "pin")],
        );

        let scan = scan(&sys.root());
        assert!(scan.readings.is_empty());
        assert_eq!(scan.availability, Availability::NotPresent);
    }

    #[test]
    fn leaves_component_sensors_unmapped() {
        let sys = Sys::new();
        // A GPU's and a voltage regulator's watts are not the host's or a supply's.
        sys.chip(
            0,
            Some("amdgpu"),
            Device::Bare {
                path: "pci0000:00/0000:03:00.0",
            },
            &[("power1_average", "90000000"), ("power1_label", "PPT")],
        );
        sys.chip(
            1,
            Some("isl68137"),
            Device::Dt {
                path: "platform/i2c-1/1-0060",
                node: "i2c@1/vrm@60",
            },
            &[("power1_input", "150000000"), ("power1_label", "pin")],
        );
        // An ACPI device without a name that is not a power meter.
        sys.chip(
            2,
            None,
            Device::Acpi {
                path: "LNXSYSTM:00/LNXTHERM:00",
                namespace: "\\_TZ_.THM0",
            },
            &[("power1_input", "1")],
        );
        // A power meter's files on its hwmon device rather than its ACPI device are not how
        // Linux registers one, and that hwmon device has no name.
        sys.chip(
            3,
            None,
            Device::Acpi {
                path: "LNXSYSTM:00/ACPI000D:00",
                namespace: "\\_SB_.PMI0",
            },
            &[("power1_average", "1"), ("power1_average_interval", "1000")],
        );

        let scan = scan(&sys.root());

        assert!(scan.readings.is_empty());
        assert_eq!(scan.availability, Availability::NotPresent);
    }

    #[test]
    fn a_sensor_that_cannot_be_read_is_a_failure_not_zero() {
        let sys = Sys::new();
        acpi_supply(
            &sys,
            0,
            "00",
            PSU0,
            &[
                ("power1_average", "garbage"),
                ("power1_average_interval", "1000"),
            ],
        );
        acpi_supply(&sys, 1, "01", PSU1, &[("power1_input", "")]);

        let scan = scan(&sys.root());

        assert_eq!(scan.readings.len(), 2);
        assert!(scan.readings.iter().all(|reading| reading.watts.is_err()));
        assert_eq!(scan.availability, Availability::NotPresent);
    }

    #[test]
    fn an_average_with_an_unusable_interval_is_a_failure_not_instantaneous() {
        for (interval, valid) in [
            (None, None),
            (Some("garbage"), None),
            (Some("0"), None),
            (Some("86400001"), None),
            (Some("18446744073709551615"), None),
            (Some("1"), Some(Duration::from_millis(1))),
            (Some("1500"), Some(Duration::from_millis(1500))),
            (Some("86400000"), Some(Duration::from_secs(86_400))),
        ] {
            let sys = Sys::new();
            let mut files = vec![("power1_average", "245000000")];
            if let Some(interval) = interval {
                files.push(("power1_average_interval", interval));
            }
            acpi_supply(&sys, 0, "00", PSU0, &files);

            let [reading] = scan(&sys.root()).readings.try_into().unwrap();
            match valid {
                Some(window) => {
                    assert_eq!(
                        (reading.watts, reading.window),
                        (Ok(245.0), window),
                        "{interval:?}"
                    )
                }
                None => assert!(reading.watts.is_err(), "{interval:?} gave {reading:?}"),
            }
        }
    }

    #[test]
    fn permission_errors_while_finding_sensors_are_not_permitted() {
        // Root reads through any mode bits, so this only proves anything as another user.
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let sys = Sys::new();
        sys.chip(
            0,
            Some("ibm_cffps2"),
            Device::Dt {
                path: "platform/i2c-3/3-0068",
                node: "i2c@1/psu@68",
            },
            &[("power1_input", "1000000"), ("power1_label", "pin")],
        );
        let chip = sys.root().join("hwmon0");

        // The label of a known supply's sensor is unreadable.
        fs::set_permissions(chip.join("power1_label"), fs::Permissions::from_mode(0o000)).unwrap();
        assert_eq!(scan(&sys.root()).availability, Availability::NotPermitted);
        fs::set_permissions(chip.join("power1_label"), fs::Permissions::from_mode(0o644)).unwrap();

        // The chip can be searched for its name but not listed.
        fs::set_permissions(&chip, fs::Permissions::from_mode(0o111)).unwrap();
        let availability = scan(&sys.root()).availability;
        fs::set_permissions(&chip, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(availability, Availability::NotPermitted);

        // The supply's device, which leads to its firmware node, cannot be entered.
        let device = sys.0.join("devices/platform/i2c-3/3-0068");
        fs::set_permissions(&device, fs::Permissions::from_mode(0o000)).unwrap();
        let availability = scan(&sys.root()).availability;
        fs::set_permissions(&device, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(availability, Availability::NotPermitted);

        // An older driver's parent device, which holds its name, cannot be entered, so whether
        // the chip is a supply is unknown. The ACPI power meter is one such driver.
        let sys = Sys::new();
        sys.meter(0, METER_PATH, METER_NAMESPACE, &[("power1_input", "1")]);
        let device = sys.0.join("devices").join(METER_PATH);
        fs::set_permissions(&device, fs::Permissions::from_mode(0o000)).unwrap();
        let availability = scan(&sys.root()).availability;
        fs::set_permissions(&device, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(availability, Availability::NotPermitted);
    }

    #[test]
    fn a_missing_root_has_nothing_present() {
        let sys = Sys::new();
        let scan = scan(&sys.0.join("absent"));
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

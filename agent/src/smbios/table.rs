//! Parser for the raw SMBIOS entry point and structure table.
//!
//! The kernel exposes the firmware's tables unmodified, so every offset and length
//! here is untrusted input. Parsing is bounds-checked throughout and skips any
//! record it cannot read rather than failing the whole table.

/// SMBIOS version from the entry point; it decides how the system UUID is encoded.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct Version {
    pub major: u8,
    pub minor: u8,
}

/// The facts the agent reads from the table.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Tables {
    pub system: Option<SystemInformation>,
    pub power_supplies: Vec<PowerSupply>,
}

/// SMBIOS type 1, System Information.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SystemInformation {
    pub uuid: Option<String>,
    pub serial_number: Option<String>,
}

/// SMBIOS type 39, System Power Supply.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct PowerSupply {
    pub group: Option<u8>,
    pub location: Option<String>,
    pub name: Option<String>,
    pub manufacturer: Option<String>,
    pub serial_number: Option<String>,
    pub asset_tag: Option<String>,
    pub model: Option<String>,
    pub revision: Option<String>,
    pub max_power_watts: Option<u16>,
    pub hot_replaceable: Option<bool>,
    pub present: Option<bool>,
    pub unplugged: Option<bool>,
    pub status: Option<&'static str>,
}

const SYSTEM_INFORMATION: u8 = 1;
const POWER_SUPPLY: u8 = 39;
const END_OF_TABLE: u8 = 127;
/// The fixed part of a type 39 record ends before its optional probe handles.
const POWER_SUPPLY_MIN_LENGTH: usize = 0x10;

/// Reads the SMBIOS version from a 2.x (`_SM_`), 3.x (`_SM3_`), or legacy (`_DMI_`)
/// entry point.
pub fn parse_version(entry_point: &[u8]) -> Option<Version> {
    if entry_point.starts_with(b"_SM3_") {
        Some(Version {
            major: *entry_point.get(0x07)?,
            minor: *entry_point.get(0x08)?,
        })
    } else if entry_point.starts_with(b"_SM_") {
        Some(Version {
            major: *entry_point.get(0x06)?,
            minor: *entry_point.get(0x07)?,
        })
    } else if entry_point.starts_with(b"_DMI_") {
        let bcd = *entry_point.get(0x0E)?;
        Some(Version {
            major: bcd >> 4,
            minor: bcd & 0x0F,
        })
    } else {
        None
    }
}

/// Parses the structure table. Without a recognizable entry point the system UUID
/// is omitted, because its byte order depends on the version.
pub fn parse(entry_point: &[u8], table: &[u8]) -> Tables {
    let version = parse_version(entry_point);
    let mut tables = Tables::default();
    for record in Records::new(table) {
        match record.kind {
            SYSTEM_INFORMATION if tables.system.is_none() => {
                tables.system = Some(system_information(&record, version));
            }
            POWER_SUPPLY => {
                if let Some(supply) = power_supply(&record) {
                    tables.power_supplies.push(supply);
                }
            }
            _ => {}
        }
    }
    tables
}

struct Record<'a> {
    kind: u8,
    formatted: &'a [u8],
    strings: Vec<&'a [u8]>,
}

impl Record<'_> {
    fn byte(&self, offset: usize) -> Option<u8> {
        self.formatted.get(offset).copied()
    }

    fn word(&self, offset: usize) -> Option<u16> {
        let bytes = self.formatted.get(offset..offset + 2)?;
        Some(u16::from_le_bytes([bytes[0], bytes[1]]))
    }

    /// String fields hold a 1-based index into the record's string set; 0 means none.
    fn string(&self, offset: usize) -> Option<String> {
        let index = usize::from(self.byte(offset)?);
        let raw = self.strings.get(index.checked_sub(1)?)?;
        let text = String::from_utf8_lossy(raw);
        crate::collectors::normalize_value(&text)
    }
}

struct Records<'a> {
    table: &'a [u8],
    offset: usize,
}

impl<'a> Records<'a> {
    fn new(table: &'a [u8]) -> Self {
        Self { table, offset: 0 }
    }
}

impl<'a> Iterator for Records<'a> {
    type Item = Record<'a>;

    fn next(&mut self) -> Option<Record<'a>> {
        let rest = self.table.get(self.offset..)?;
        let (&kind, &length) = (rest.first()?, rest.get(1)?);
        let length = usize::from(length);
        // A header shorter than four bytes would make the walk stop advancing.
        if length < 4 || kind == END_OF_TABLE {
            return None;
        }
        let formatted = rest.get(..length)?;
        let unformatted = &rest[length..];
        // The string set ends with two NULs; a record without strings is just "\0\0".
        let end = unformatted.windows(2).position(|pair| pair == [0, 0])?;
        let strings = if end == 0 {
            Vec::new()
        } else {
            unformatted[..end].split(|&byte| byte == 0).collect()
        };
        self.offset += length + end + 2;
        Some(Record {
            kind,
            formatted,
            strings,
        })
    }
}

fn system_information(record: &Record, version: Option<Version>) -> SystemInformation {
    SystemInformation {
        uuid: version.and_then(|version| uuid(record.formatted.get(0x08..0x18)?, version)),
        serial_number: record.string(0x07),
    }
}

/// Formats the system UUID as the kernel's `product_uuid` does. From SMBIOS 2.6 the
/// first three fields are little-endian; earlier tables store all bytes in order.
fn uuid(bytes: &[u8], version: Version) -> Option<String> {
    if bytes.iter().all(|&byte| byte == 0x00) || bytes.iter().all(|&byte| byte == 0xFF) {
        return None;
    }
    let mut ordered: [u8; 16] = bytes.try_into().ok()?;
    if version >= (Version { major: 2, minor: 6 }) {
        ordered[0..4].reverse();
        ordered[4..6].reverse();
        ordered[6..8].reverse();
    }
    Some(uuid::Uuid::from_bytes(ordered).hyphenated().to_string())
}

fn power_supply(record: &Record) -> Option<PowerSupply> {
    if record.formatted.len() < POWER_SUPPLY_MIN_LENGTH {
        return None;
    }
    let characteristics = record.word(0x0E)?;
    let supply = PowerSupply {
        // Group 0 means the supply is not part of a redundant group.
        group: record.byte(0x04).filter(|&group| group != 0),
        location: record.string(0x05),
        name: record.string(0x06),
        manufacturer: record.string(0x07),
        serial_number: record.string(0x08),
        asset_tag: record.string(0x09),
        model: record.string(0x0A),
        revision: record.string(0x0B),
        max_power_watts: record.word(0x0C).filter(|&watts| watts != 0x8000),
        hot_replaceable: Some(characteristics & 0x0001 != 0),
        present: Some(characteristics & 0x0002 != 0),
        unplugged: Some(characteristics & 0x0004 != 0),
        status: match (characteristics >> 7) & 0x07 {
            0b011 => Some("ok"),
            0b100 => Some("non_critical"),
            0b101 => Some("critical"),
            _ => None,
        },
    };
    // Vendors ship placeholder records with every string and the capacity unset;
    // those describe no supply, so they report nothing rather than an empty one.
    let described = supply.location.is_some()
        || supply.name.is_some()
        || supply.manufacturer.is_some()
        || supply.serial_number.is_some()
        || supply.model.is_some()
        || supply.max_power_watts.is_some();
    described.then_some(supply)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Builds one structure: formatted area (header included) followed by its strings.
    pub(crate) fn record(kind: u8, body: &[u8], strings: &[&str]) -> Vec<u8> {
        let mut bytes = vec![kind, (body.len() + 4) as u8, 0x00, 0x01];
        bytes.extend_from_slice(body);
        if strings.is_empty() {
            bytes.extend_from_slice(&[0, 0]);
        } else {
            for string in strings {
                bytes.extend_from_slice(string.as_bytes());
                bytes.push(0);
            }
            bytes.push(0);
        }
        bytes
    }

    pub(crate) fn entry_point_3(minor: u8) -> Vec<u8> {
        let mut entry = b"_SM3_".to_vec();
        entry.extend_from_slice(&[0x00, 0x18, 0x03, minor, 0x00, 0x01, 0x00]);
        entry.resize(0x18, 0);
        entry
    }

    pub(crate) const UUID_BYTES: [u8; 16] = [
        0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE,
        0xFF,
    ];

    pub(crate) fn system_record(uuid: [u8; 16], serial: &str) -> Vec<u8> {
        // Manufacturer, product, version, serial (string 4), then the UUID.
        let mut body = vec![1, 2, 3, 4];
        body.extend_from_slice(&uuid);
        body.push(0x06); // wake-up type
        record(1, &body, &["Vendor", "Product", "1.0", serial])
    }

    pub(crate) fn power_supply_record(characteristics: u16, watts: u16) -> Vec<u8> {
        let mut body = vec![1, 1, 2, 3, 4, 5, 6, 7];
        body.extend_from_slice(&watts.to_le_bytes());
        body.extend_from_slice(&characteristics.to_le_bytes());
        body.extend_from_slice(&[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
        record(
            39,
            &body,
            &[
                "PSU 1",
                "PWR SPLY,1100W",
                "DELL",
                "CN1797255H0123",
                "To Be Filled By O.E.M.",
                "0PJMDN",
                "A00",
            ],
        )
    }

    fn end() -> Vec<u8> {
        record(127, &[], &[])
    }

    #[test]
    fn reads_versions_from_every_entry_point_format() {
        assert_eq!(
            parse_version(&entry_point_3(4)),
            Some(Version { major: 3, minor: 4 })
        );
        let mut two = b"_SM_".to_vec();
        two.extend_from_slice(&[0x00, 0x1F, 0x02, 0x08]);
        assert_eq!(parse_version(&two), Some(Version { major: 2, minor: 8 }));
        let mut legacy = b"_DMI_".to_vec();
        legacy.resize(0x0E, 0);
        legacy.push(0x24);
        assert_eq!(parse_version(&legacy), Some(Version { major: 2, minor: 4 }));
        assert_eq!(parse_version(b"_SM3"), None);
        assert_eq!(parse_version(b"junk-entry-point"), None);
    }

    #[test]
    fn formats_the_system_uuid_like_the_kernel_for_each_version() {
        let table = [system_record(UUID_BYTES, "SN-1"), end()].concat();
        let modern = parse(&entry_point_3(0), &table).system.unwrap();
        assert_eq!(
            modern.uuid.as_deref(),
            Some("00112233-4455-6677-8899-aabbccddeeff")
        );
        assert_eq!(modern.serial_number.as_deref(), Some("SN-1"));

        let mut legacy = b"_SM_".to_vec();
        legacy.extend_from_slice(&[0x00, 0x1F, 0x02, 0x05]);
        let old = parse(&legacy, &table).system.unwrap();
        assert_eq!(
            old.uuid.as_deref(),
            Some("33221100-5544-7766-8899-aabbccddeeff")
        );

        let unversioned = parse(b"", &table).system.unwrap();
        assert_eq!(unversioned.uuid, None);
        assert_eq!(unversioned.serial_number.as_deref(), Some("SN-1"));
    }

    #[test]
    fn treats_unset_uuids_and_placeholder_serials_as_absent() {
        for uuid in [[0x00; 16], [0xFF; 16]] {
            let table = [system_record(uuid, "Default string"), end()].concat();
            let system = parse(&entry_point_3(0), &table).system.unwrap();
            assert_eq!(system, SystemInformation::default());
        }
    }

    #[test]
    fn reads_power_supply_records() {
        // Hot-replaceable, present, plugged in, status OK, auto-switching, switching type.
        let characteristics = 0b0000_1001_1010_0011;
        let table = [
            record(0, &[0; 0x14], &["BIOS vendor"]),
            power_supply_record(characteristics, 1100),
            end(),
        ]
        .concat();
        let supplies = parse(&entry_point_3(0), &table).power_supplies;
        assert_eq!(
            supplies,
            [PowerSupply {
                group: Some(1),
                location: Some("PSU 1".into()),
                name: Some("PWR SPLY,1100W".into()),
                manufacturer: Some("DELL".into()),
                serial_number: Some("CN1797255H0123".into()),
                asset_tag: None,
                model: Some("0PJMDN".into()),
                revision: Some("A00".into()),
                max_power_watts: Some(1100),
                hot_replaceable: Some(true),
                present: Some(true),
                unplugged: Some(false),
                status: Some("ok"),
            }]
        );
    }

    #[test]
    fn reports_unknown_capacity_and_failed_status() {
        let critical = 0b101 << 7 | 0b100;
        let table = [power_supply_record(critical, 0x8000), end()].concat();
        let supply = &parse(&entry_point_3(0), &table).power_supplies[0];
        assert_eq!(supply.max_power_watts, None);
        assert_eq!(supply.status, Some("critical"));
        assert_eq!(supply.unplugged, Some(true));
        assert_eq!(supply.present, Some(false));
    }

    #[test]
    fn skips_empty_and_truncated_power_supply_records() {
        let mut empty = vec![0, 0, 0, 0, 0, 0, 0, 0];
        empty.extend_from_slice(&0x8000u16.to_le_bytes());
        empty.extend_from_slice(&[0, 0]);
        let table = [
            record(39, &empty, &[]),
            record(39, &[1, 1, 2], &["PSU 1", "Name"]),
            end(),
        ]
        .concat();
        assert!(parse(&entry_point_3(0), &table).power_supplies.is_empty());
    }

    #[test]
    fn stops_safely_on_malformed_tables() {
        let supply = power_supply_record(0b011 << 7, 750);
        // Truncated anywhere, the parser keeps the complete records before the cut.
        for cut in 0..supply.len() {
            let table = [system_record(UUID_BYTES, "SN-1"), supply[..cut].to_vec()].concat();
            let tables = parse(&entry_point_3(0), &table);
            assert!(tables.system.is_some());
            assert!(tables.power_supplies.is_empty());
        }
        // A zero or undersized length must not loop forever.
        assert_eq!(
            parse(&entry_point_3(0), &[39, 0, 0, 0, 0, 0]),
            Tables::default()
        );
        assert_eq!(
            parse(&entry_point_3(0), &[39, 3, 0, 0, 0, 0]),
            Tables::default()
        );
        // Records after the end-of-table marker are ignored.
        let table = [end(), power_supply_record(0b011 << 7, 750)].concat();
        assert!(parse(&entry_point_3(0), &table).power_supplies.is_empty());
    }
}

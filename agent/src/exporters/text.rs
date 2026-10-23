//! A bounded reader for the Prometheus text exposition format.
//!
//! Only series whose metric name the caller wants are kept; every other line is still counted
//! against the series limit, so a huge or hostile response fails the scrape instead of growing
//! without bound.

use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Sample lines in one response, kept or not.
    pub max_series: usize,
    pub max_labels: usize,
    /// Kept samples.
    pub max_samples: usize,
}

impl Default for Limits {
    /// A node_exporter on a large host emits a few thousand series.
    fn default() -> Self {
        Self {
            max_series: 50_000,
            max_labels: 32,
            max_samples: 2_000,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sample {
    pub name: String,
    pub labels: BTreeMap<String, String>,
    pub value: f64,
}

/// Parses `text`, keeping the samples whose metric name `wanted` accepts.
pub fn parse(
    text: &str,
    limits: Limits,
    wanted: impl Fn(&str) -> bool,
) -> Result<Vec<Sample>, String> {
    let mut series = 0;
    let mut samples = Vec::new();
    for (number, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        series += 1;
        if series > limits.max_series {
            return Err(format!("more than {} series", limits.max_series));
        }
        let name_end = line
            .find(|c: char| c == '{' || c.is_ascii_whitespace())
            .ok_or_else(|| format!("line {}: no value", number + 1))?;
        let name = &line[..name_end];
        if !valid_name(name) {
            return Err(format!("line {}: invalid metric name", number + 1));
        }
        if !wanted(name) {
            continue;
        }
        let (labels, rest) = if line[name_end..].starts_with('{') {
            labels(&line[name_end + 1..], limits.max_labels)
                .map_err(|error| format!("line {}: {error}", number + 1))?
        } else {
            (BTreeMap::new(), &line[name_end..])
        };
        let value = rest
            .split_ascii_whitespace()
            .next()
            .ok_or_else(|| format!("line {}: no value", number + 1))?;
        let value =
            parse_value(value).ok_or_else(|| format!("line {}: invalid value", number + 1))?;
        if samples.len() == limits.max_samples {
            return Err(format!("more than {} mapped samples", limits.max_samples));
        }
        samples.push(Sample {
            name: name.to_owned(),
            labels,
            value,
        });
    }
    Ok(samples)
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_' || c == ':')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == ':')
}

/// Parses `name="value",...}` and returns the labels and what follows the closing brace.
fn labels(mut rest: &str, max_labels: usize) -> Result<(BTreeMap<String, String>, &str), String> {
    let mut labels = BTreeMap::new();
    loop {
        rest = rest.trim_start();
        if let Some(after) = rest.strip_prefix('}') {
            return Ok((labels, after));
        }
        let equals = rest.find('=').ok_or("unterminated labels")?;
        let name = rest[..equals].trim();
        if !valid_name(name) || name.contains(':') {
            return Err("invalid label name".into());
        }
        rest = rest[equals + 1..]
            .trim_start()
            .strip_prefix('"')
            .ok_or("label value is not quoted")?;
        let mut value = String::new();
        let mut chars = rest.char_indices();
        let end = loop {
            match chars.next() {
                Some((index, '"')) => break index,
                Some((_, '\\')) => match chars.next() {
                    Some((_, 'n')) => value.push('\n'),
                    Some((_, '\\')) => value.push('\\'),
                    Some((_, '"')) => value.push('"'),
                    _ => return Err("invalid escape in label value".into()),
                },
                Some((_, c)) => value.push(c),
                None => return Err("unterminated label value".into()),
            }
        };
        if labels.len() == max_labels {
            return Err(format!("more than {max_labels} labels"));
        }
        labels.insert(name.to_owned(), value);
        rest = rest[end + 1..].trim_start();
        rest = rest.strip_prefix(',').unwrap_or(rest);
    }
}

fn parse_value(value: &str) -> Option<f64> {
    match value {
        "+Inf" => Some(f64::INFINITY),
        "-Inf" => Some(f64::NEG_INFINITY),
        "NaN" => Some(f64::NAN),
        value => value.parse().ok(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all(_name: &str) -> bool {
        true
    }

    #[test]
    fn reads_wanted_samples_with_labels() {
        let text = r#"
# HELP ipmi_dcmi_power_consumption_watts Current power consumption in Watts.
# TYPE ipmi_dcmi_power_consumption_watts gauge
ipmi_dcmi_power_consumption_watts 312
ipmi_power_watts{id="98",name="PSU1 Input"} 151.5 1700000000000
go_goroutines 9
node_hwmon_chip_names{chip="acpi_ACPI000D_00",chip_name="acpi_power_meter"} 1
weird{a="quote \" and \\ and \n",b="x",} 1e3
"#;
        let samples = parse(text, Limits::default(), |name| name != "go_goroutines").unwrap();

        assert_eq!(samples.len(), 4);
        assert_eq!(samples[0].name, "ipmi_dcmi_power_consumption_watts");
        assert!(samples[0].labels.is_empty());
        assert_eq!(samples[0].value, 312.0);
        assert_eq!(samples[1].labels["name"], "PSU1 Input");
        assert_eq!(samples[1].value, 151.5);
        assert_eq!(samples[2].labels["chip_name"], "acpi_power_meter");
        assert_eq!(samples[3].labels["a"], "quote \" and \\ and \n");
        assert_eq!(samples[3].value, 1000.0);
    }

    #[test]
    fn special_values_parse_and_the_caller_judges_them() {
        let samples = parse("a NaN\nb +Inf\n", Limits::default(), all).unwrap();
        assert!(samples[0].value.is_nan());
        assert!(samples[1].value.is_infinite());
    }

    #[test]
    fn malformed_lines_fail_the_whole_scrape() {
        for text in [
            "metric",
            "metric{a=\"1\" 2",
            "metric{a=1} 2",
            "metric{a=\"1\\x\"} 2",
            "metric seven",
            "9metric 1",
            "metric{a-b=\"1\"} 2",
        ] {
            assert!(parse(text, Limits::default(), all).is_err(), "{text:?}");
        }
    }

    #[test]
    fn limits_count_every_series_but_keep_only_wanted_ones() {
        let limits = Limits {
            max_series: 3,
            max_labels: 2,
            max_samples: 1,
        };
        assert_eq!(
            parse("a 1\nb 2\nc 3\n", limits, |name| name == "a")
                .unwrap()
                .len(),
            1
        );
        assert!(parse("a 1\nb 2\nc 3\nd 4\n", limits, |name| name == "a").is_err());
        assert!(parse("a 1\na 2\n", limits, all).is_err());
        assert!(parse("a{x=\"1\",y=\"2\",z=\"3\"} 1\n", limits, all).is_err());
    }
}

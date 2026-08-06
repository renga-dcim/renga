//! Owned, platform-neutral network facts and the adapter that obtains them.

use std::{collections::BTreeMap, io, net::IpAddr};

const MAX_ATTEMPTS: usize = 5;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum AddressFamily {
    Ipv4,
    Ipv6,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct NetworkAddress {
    pub ip: IpAddr,
    pub prefix: u8,
    pub family: AddressFamily,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct NetworkInterface {
    pub name: String,
    pub index: u32,
    pub mac: Option<String>,
    pub mtu: Option<u32>,
    pub up: bool,
    pub running: bool,
    pub loopback: bool,
    pub addresses: Vec<NetworkAddress>,
}

pub trait NetworkFactsSource {
    /// `Err` means unavailable; `Ok([])` is an authoritative empty snapshot.
    fn collect(&self) -> io::Result<Vec<NetworkInterface>>;
}

#[derive(Clone, Debug)]
struct RawInterface {
    name: String,
    index: u32,
    mac: Option<String>,
    mtu: u32,
    up: bool,
    running: bool,
    loopback: bool,
}

#[derive(Clone, Debug)]
struct RawAddress {
    index: u32,
    address: NetworkAddress,
}

trait DumpProvider {
    fn interfaces(&self) -> io::Result<Vec<RawInterface>>;
    fn addresses(&self) -> io::Result<Vec<RawAddress>>;
}

pub struct GetifsSource;
struct GetifsDumpProvider;

impl DumpProvider for GetifsDumpProvider {
    fn interfaces(&self) -> io::Result<Vec<RawInterface>> {
        getifs::interfaces()?
            .into_iter()
            .map(|interface| {
                let flags = interface.flags();
                Ok(RawInterface {
                    name: interface.name().to_string(),
                    index: interface.index(),
                    mac: interface
                        .mac_addr()
                        .map(|mac| mac.to_string().to_lowercase()),
                    mtu: interface.mtu(),
                    up: flags.contains(getifs::Flags::UP),
                    running: flags.contains(getifs::Flags::RUNNING),
                    loopback: flags.contains(getifs::Flags::LOOPBACK),
                })
            })
            .collect()
    }

    fn addresses(&self) -> io::Result<Vec<RawAddress>> {
        getifs::interface_addrs()?
            .into_iter()
            .map(|network| match network {
                getifs::IfNet::V4(v4) => RawAddress {
                    index: v4.index(),
                    address: NetworkAddress {
                        ip: v4.addr().into(),
                        prefix: v4.prefix_len(),
                        family: AddressFamily::Ipv4,
                    },
                },
                getifs::IfNet::V6(v6) => RawAddress {
                    index: v6.index(),
                    address: NetworkAddress {
                        ip: v6.addr().into(),
                        prefix: v6.prefix_len(),
                        family: AddressFamily::Ipv6,
                    },
                },
            })
            .map(Ok)
            .collect()
    }
}

impl NetworkFactsSource for GetifsSource {
    fn collect(&self) -> io::Result<Vec<NetworkInterface>> {
        stable_snapshot(&GetifsDumpProvider)
    }
}

fn stable_snapshot(provider: &dyn DumpProvider) -> io::Result<Vec<NetworkInterface>> {
    let mut previous = None;
    let mut last_error = None;
    for _ in 0..MAX_ATTEMPTS {
        match snapshot(provider) {
            Ok(current) => {
                if previous.as_ref() == Some(&current) {
                    return Ok(current);
                }
                previous = Some(current);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                previous = None;
                last_error = Some(error);
            }
            Err(error) => return Err(error),
        }
    }
    Err(last_error.unwrap_or_else(|| io::Error::other("network snapshot remained unstable")))
}

fn snapshot(provider: &dyn DumpProvider) -> io::Result<Vec<NetworkInterface>> {
    let interfaces = provider.interfaces()?;
    let mut addresses: BTreeMap<u32, Vec<NetworkAddress>> = BTreeMap::new();
    for address in provider.addresses()? {
        addresses
            .entry(address.index)
            .or_default()
            .push(address.address);
    }
    let mut result = Vec::with_capacity(interfaces.len());
    for interface in interfaces {
        let mut interface_addresses = addresses.remove(&interface.index).unwrap_or_default();
        interface_addresses.sort();
        result.push(NetworkInterface {
            name: interface.name,
            index: interface.index,
            mac: interface.mac.filter(|mac| mac != "00:00:00:00:00:00"),
            mtu: (interface.mtu != 0).then_some(interface.mtu),
            up: interface.up,
            running: interface.running,
            loopback: interface.loopback,
            addresses: interface_addresses,
        });
    }
    if !addresses.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "address references unknown interface index",
        ));
    }
    result.sort();
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, collections::VecDeque};

    struct Fake(RefCell<VecDeque<io::Result<(Vec<RawInterface>, Vec<RawAddress>)>>>);
    impl DumpProvider for Fake {
        fn interfaces(&self) -> io::Result<Vec<RawInterface>> {
            let mut pair = self.0.borrow_mut().pop_front().unwrap()?;
            let interfaces = std::mem::take(&mut pair.0);
            self.0.borrow_mut().push_front(Ok(pair));
            Ok(interfaces)
        }
        fn addresses(&self) -> io::Result<Vec<RawAddress>> {
            self.0.borrow_mut().pop_front().unwrap().map(|pair| pair.1)
        }
    }
    fn iface(index: u32, name: &str) -> RawInterface {
        RawInterface {
            name: name.into(),
            index,
            mac: None,
            mtu: 0,
            up: false,
            running: false,
            loopback: false,
        }
    }
    fn fake(items: Vec<io::Result<(Vec<RawInterface>, Vec<RawAddress>)>>) -> Fake {
        Fake(RefCell::new(items.into()))
    }

    #[test]
    fn accepts_two_identical_sorted_snapshots() {
        let source = fake(vec![
            Ok((vec![iface(2, "z")], vec![])),
            Ok((vec![iface(2, "z")], vec![])),
        ]);
        assert_eq!(stable_snapshot(&source).unwrap()[0].name, "z");
    }
    #[test]
    fn retries_instability_and_interrupted_errors() {
        let source = fake(vec![
            Err(io::Error::from(io::ErrorKind::Interrupted)),
            Ok((vec![iface(1, "a")], vec![])),
            Ok((vec![iface(2, "b")], vec![])),
            Ok((vec![iface(2, "b")], vec![])),
        ]);
        assert_eq!(stable_snapshot(&source).unwrap()[0].index, 2);
    }
    #[test]
    fn retries_unknown_address_index_then_accepts_identical_snapshots() {
        let address = RawAddress {
            index: 9,
            address: NetworkAddress {
                ip: "127.0.0.1".parse().unwrap(),
                prefix: 8,
                family: AddressFamily::Ipv4,
            },
        };
        let source = fake(vec![
            Ok((vec![iface(1, "a")], vec![address])),
            Ok((vec![iface(1, "a")], vec![])),
            Ok((vec![iface(1, "a")], vec![])),
        ]);

        assert_eq!(stable_snapshot(&source).unwrap()[0].index, 1);
    }
    #[test]
    fn interrupted_sample_breaks_consecutive_snapshot_sequence() {
        let unknown_address = RawAddress {
            index: 9,
            address: NetworkAddress {
                ip: "127.0.0.1".parse().unwrap(),
                prefix: 8,
                family: AddressFamily::Ipv4,
            },
        };
        let source = fake(vec![
            Ok((vec![iface(1, "a")], vec![])),
            Ok((vec![iface(1, "a")], vec![unknown_address])),
            Ok((vec![iface(1, "a")], vec![])),
            Ok((vec![iface(2, "b")], vec![])),
            Ok((vec![iface(2, "b")], vec![])),
        ]);

        assert_eq!(stable_snapshot(&source).unwrap()[0].index, 2);
    }
    #[test]
    fn persistent_unknown_address_index_fails_after_attempt_bound() {
        let items = (0..MAX_ATTEMPTS)
            .map(|_| {
                Ok((
                    vec![iface(1, "a")],
                    vec![RawAddress {
                        index: 9,
                        address: NetworkAddress {
                            ip: "127.0.0.1".parse().unwrap(),
                            prefix: 8,
                            family: AddressFamily::Ipv4,
                        },
                    }],
                ))
            })
            .collect();

        let error = stable_snapshot(&fake(items)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
    }
    #[test]
    fn instability_is_unavailable_after_bound() {
        let items = (0..MAX_ATTEMPTS)
            .map(|i| Ok((vec![iface(i as u32, "a")], vec![])))
            .collect();
        assert!(stable_snapshot(&fake(items)).is_err());
    }
    #[test]
    fn real_getifs_smoke_has_normalized_values_when_available() {
        if let Ok(facts) = GetifsSource.collect() {
            for interface in facts {
                assert!(!interface.name.is_empty());
                assert!(interface.mtu.is_none_or(|mtu| mtu > 0));
                assert!(interface.mac.is_none_or(|mac| mac == mac.to_lowercase()));
                for address in interface.addresses {
                    assert!(
                        address.prefix
                            <= if matches!(address.family, AddressFamily::Ipv4) {
                                32
                            } else {
                                128
                            }
                    );
                }
            }
        }
    }
}

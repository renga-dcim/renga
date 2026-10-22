//! Read-only switch polling over gNMI with OpenConfig models (RFD 11, "Switch collection"), for
//! switches whose SNMP agents are incomplete. It reports the same switch resource, in the same
//! `targets` reports, as the SNMP poller.

pub mod config;
pub mod openconfig;
pub mod proto;
pub mod tree;

//! SMBIOS firmware tables: the parser, and the boot-scoped snapshot through which the
//! unprivileged agent reads tables that only root can open.

pub mod table;

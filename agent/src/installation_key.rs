//! The installation's Ed25519 key pair (RFD 13, "Installation credentials").
//!
//! An intake key proves only the organization. This key proves the
//! installation: the agent presents its public half on every check-in, an
//! owner or admin approves it by fingerprint, and later RFD 13 phases sign
//! privileged job leases with the private half. The private key never leaves
//! the state directory, where it is created once with mode 0600.

use std::{fmt, fs, io::Write, path::Path};

use base64::engine::general_purpose::{STANDARD_NO_PAD, URL_SAFE_NO_PAD};
use base64::Engine;
use ring::{
    digest,
    rand::SystemRandom,
    signature::{Ed25519KeyPair, KeyPair},
};

use crate::identity;

const KEY_FILE: &str = "installation-key";

#[derive(Debug)]
pub struct KeyError(String);

impl fmt::Display for KeyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for KeyError {}

impl From<identity::IdentityError> for KeyError {
    fn from(error: identity::IdentityError) -> Self {
        Self(error.to_string())
    }
}

pub struct InstallationKey {
    pair: Ed25519KeyPair,
}

impl fmt::Debug for InstallationKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("InstallationKey")
            .field("fingerprint", &self.fingerprint())
            .finish_non_exhaustive()
    }
}

impl InstallationKey {
    /// Reads the persisted key pair or creates it once. Concurrent first
    /// starts settle on whichever pair was persisted first.
    pub fn load_or_create(state_directory: &Path) -> Result<Self, KeyError> {
        identity::prepare_state_directory(state_directory)?;
        let path = state_directory.join(KEY_FILE);
        if !path.exists() {
            persist_new_key(state_directory, &path)?;
        }
        Self::load(state_directory)
    }

    /// Reads the persisted key pair without ever creating one, so a command
    /// run as another user cannot leave a key the service cannot read.
    pub fn load(state_directory: &Path) -> Result<Self, KeyError> {
        let path = state_directory.join(KEY_FILE);
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            KeyError(format!(
                "cannot inspect installation key {}: {error}",
                path.display()
            ))
        })?;
        if !metadata.file_type().is_file() {
            return Err(KeyError(format!(
                "installation key {} is not a regular file",
                path.display()
            )));
        }
        let pkcs8 = fs::read(&path).map_err(|error| {
            KeyError(format!(
                "cannot read installation key {}: {error}",
                path.display()
            ))
        })?;
        let pair = Ed25519KeyPair::from_pkcs8(&pkcs8).map_err(|_| {
            KeyError(format!(
                "installation key {} is not an Ed25519 key",
                path.display()
            ))
        })?;
        Ok(Self { pair })
    }

    /// The raw 32-byte public key in unpadded base64url, as check-ins send it.
    pub fn public_key(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.pair.public_key().as_ref())
    }

    /// `SHA256:` and the unpadded base64 SHA-256 of the raw public key, the
    /// same string the Collectors page shows for approval.
    pub fn fingerprint(&self) -> String {
        let digest = digest::digest(&digest::SHA256, self.pair.public_key().as_ref());
        format!("SHA256:{}", STANDARD_NO_PAD.encode(digest.as_ref()))
    }

    /// Signs `message` with the private key.
    pub fn sign(&self, message: &[u8]) -> Vec<u8> {
        self.pair.sign(message).as_ref().to_vec()
    }
}

fn persist_new_key(state_directory: &Path, path: &Path) -> Result<(), KeyError> {
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new())
        .map_err(|_| KeyError("cannot generate an installation key".into()))?;
    let temporary = state_directory.join(format!(".installation-key-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = identity::create_private_file(&temporary)?;
        file.write_all(pkcs8.as_ref())
            .and_then(|()| file.sync_all())
            .map_err(|error| KeyError(format!("cannot write installation key: {error}")))?;

        // A hard link never replaces an existing file, so a key another
        // process persisted first wins and both processes read it back.
        match fs::hard_link(&temporary, path) {
            Ok(()) => Ok(identity::sync_state_directory(state_directory)?),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(error) => Err(KeyError(format!(
                "cannot persist installation key {}: {error}",
                path.display()
            ))),
        }
    })();
    let _ = fs::remove_file(temporary);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{UnparsedPublicKey, ED25519};

    fn state_directory() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("renga-key-{}", uuid::Uuid::new_v4()))
    }

    #[test]
    fn creates_the_key_once_and_reads_it_back() {
        let state = state_directory();
        let first = InstallationKey::load_or_create(&state).unwrap();
        let second = InstallationKey::load_or_create(&state).unwrap();

        assert_eq!(first.public_key(), second.public_key());
        assert_eq!(first.public_key().len(), 43);
        assert!(first.fingerprint().starts_with("SHA256:"));
        assert_eq!(first.fingerprint().len(), "SHA256:".len() + 43);
    }

    #[cfg(unix)]
    #[test]
    fn keeps_the_private_key_private() {
        use std::os::unix::fs::PermissionsExt;

        let state = state_directory();
        InstallationKey::load_or_create(&state).unwrap();
        let mode = fs::metadata(state.join(KEY_FILE))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn load_never_creates_a_key() {
        let state = state_directory();
        fs::create_dir_all(&state).unwrap();
        assert!(InstallationKey::load(&state).is_err());
        assert!(!state.join(KEY_FILE).exists());
    }

    #[test]
    fn rejects_a_file_that_is_not_a_key() {
        let state = state_directory();
        fs::create_dir_all(&state).unwrap();
        fs::write(state.join(KEY_FILE), b"not a key").unwrap();
        assert!(InstallationKey::load_or_create(&state).is_err());
    }

    #[test]
    fn signatures_verify_with_the_presented_public_key() {
        let key = InstallationKey::load_or_create(&state_directory()).unwrap();
        let public = URL_SAFE_NO_PAD.decode(key.public_key()).unwrap();
        let signature = key.sign(b"lease");

        UnparsedPublicKey::new(&ED25519, public)
            .verify(b"lease", &signature)
            .unwrap();
    }

    #[test]
    fn fingerprint_matches_the_server_format() {
        // Renga.Inventory.InstallationKey.fingerprint/1 hashes the raw key.
        let key = InstallationKey::load_or_create(&state_directory()).unwrap();
        let public = URL_SAFE_NO_PAD.decode(key.public_key()).unwrap();
        let expected = STANDARD_NO_PAD.encode(digest::digest(&digest::SHA256, &public).as_ref());
        assert_eq!(key.fingerprint(), format!("SHA256:{expected}"));
    }
}

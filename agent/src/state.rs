//! Durable installation identity and key-bound credential state.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::SigningKey;
use fs2::FileExt;
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use std::{
    fmt,
    fs::File,
    io::{Read, Write},
    path::Path,
};

#[derive(Clone, Serialize, Deserialize)]
pub struct State {
    pub installation_id: uuid::Uuid,
    pub private_key: [u8; 32],
    pub credential_id: Option<String>,
    pub credential_expires_at: Option<chrono::DateTime<chrono::Utc>>,
}

impl fmt::Debug for State {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("State")
            .field("installation_id", &self.installation_id)
            .field("private_key", &"[REDACTED]")
            .field("credential_id", &"[REDACTED]")
            .field("credential_expires_at", &self.credential_expires_at)
            .finish()
    }
}

impl State {
    pub fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.private_key)
    }

    pub fn validate(&self) -> Result<(), Box<dyn std::error::Error>> {
        match (&self.credential_id, self.credential_expires_at) {
            (None, None) => Ok(()),
            (Some(id), Some(_expiry)) if canonical_credential(id) => Ok(()),
            _ => Err("invalid or expired enrollment state".into()),
        }
    }
}

pub fn canonical_credential(value: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(value)
        .ok()
        .is_some_and(|bytes| bytes.len() == 32 && URL_SAFE_NO_PAD.encode(bytes) == value)
}

#[cfg(unix)]
pub struct Store {
    dir: File,
    _lock: File,
}

#[cfg(unix)]
impl Store {
    pub fn open(path: &Path) -> Result<(Self, State), Box<dyn std::error::Error>> {
        use std::os::unix::{
            ffi::OsStrExt,
            io::{AsRawFd, FromRawFd},
        };
        let cpath = std::ffi::CString::new(path.as_os_str().as_bytes())?;
        if unsafe { libc::mkdir(cpath.as_ptr(), 0o700) } != 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::AlreadyExists {
                return Err(error.into());
            }
        }
        let fd = unsafe {
            libc::open(
                cpath.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let dir = unsafe { File::from_raw_fd(fd) };
        validate_fd(&dir, libc::S_IFDIR, 0o700)?;
        let lock = openat(
            dir.as_raw_fd(),
            "state.lock",
            libc::O_RDWR | libc::O_CREAT,
            0o600,
        )?;
        validate_fd(&lock, libc::S_IFREG, 0o600)?;
        lock.lock_exclusive()?;
        let store = Self { dir, _lock: lock };
        let state = match openat(store.dir.as_raw_fd(), "state.json", libc::O_RDWR, 0) {
            Ok(mut file) => {
                validate_fd(&file, libc::S_IFREG, 0o600)?;
                let mut bytes = Vec::new();
                file.read_to_end(&mut bytes)?;
                let state: State = serde_json::from_slice(&bytes)?;
                state.validate()?;
                state
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let state = State {
                    installation_id: uuid::Uuid::new_v4(),
                    private_key: SigningKey::generate(&mut OsRng).to_bytes(),
                    credential_id: None,
                    credential_expires_at: None,
                };
                store.save(&state)?;
                state
            }
            Err(e) => return Err(e.into()),
        };
        Ok((store, state))
    }

    pub fn save(&self, state: &State) -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::io::AsRawFd;
        state.validate()?;
        let name = format!(".state-{}.tmp", uuid::Uuid::new_v4());
        let mut file = openat(
            self.dir.as_raw_fd(),
            &name,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            0o600,
        )?;
        let result = (|| {
            file.write_all(&serde_json::to_vec(state)?)?;
            file.sync_all()?;
            let old = std::ffi::CString::new(name.as_bytes())?;
            let new = cstr("state.json")?;
            if unsafe {
                libc::renameat(
                    self.dir.as_raw_fd(),
                    old.as_ptr(),
                    self.dir.as_raw_fd(),
                    new.as_ptr(),
                )
            } != 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            self.dir.sync_all()?;
            Ok::<_, Box<dyn std::error::Error>>(())
        })();
        if result.is_err() {
            if let Ok(name) = std::ffi::CString::new(name) {
                unsafe {
                    libc::unlinkat(self.dir.as_raw_fd(), name.as_ptr(), 0);
                }
            }
        }
        result
    }
}

#[cfg(unix)]
fn cstr(name: &str) -> std::io::Result<std::ffi::CString> {
    std::ffi::CString::new(name).map_err(|_| std::io::ErrorKind::InvalidInput.into())
}

#[cfg(unix)]
fn openat(
    dir: libc::c_int,
    name: &str,
    flags: libc::c_int,
    mode: libc::mode_t,
) -> std::io::Result<File> {
    use std::os::unix::io::FromRawFd;
    let name = cstr(name)?;
    let fd = unsafe {
        libc::openat(
            dir,
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode,
        )
    };
    if fd < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

#[cfg(unix)]
fn validate_fd(file: &File, kind: libc::mode_t, permissions: libc::mode_t) -> std::io::Result<()> {
    use std::os::unix::io::AsRawFd;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(file.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let stat = unsafe { stat.assume_init() };
    if stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & libc::S_IFMT != kind
        || stat.st_mode & 0o777 != permissions
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "state object has unsafe owner, type, or permissions",
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
pub struct Store {
    dir: std::path::PathBuf,
    _lock: File,
}

#[cfg(not(unix))]
impl Store {
    pub fn open(path: &Path) -> Result<(Self, State), Box<dyn std::error::Error>> {
        std::fs::create_dir_all(path)?;
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(path.join("state.lock"))?;
        lock.lock_exclusive()?;
        let store = Self {
            dir: path.into(),
            _lock: lock,
        };
        let state = match std::fs::read(path.join("state.json")) {
            Ok(bytes) => {
                let state: State = serde_json::from_slice(&bytes)?;
                state.validate()?;
                state
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let state = State {
                    installation_id: uuid::Uuid::new_v4(),
                    private_key: SigningKey::generate(&mut OsRng).to_bytes(),
                    credential_id: None,
                    credential_expires_at: None,
                };
                store.save(&state)?;
                state
            }
            Err(e) => return Err(e.into()),
        };
        Ok((store, state))
    }
    pub fn save(&self, state: &State) -> Result<(), Box<dyn std::error::Error>> {
        state.validate()?;
        let tmp = self
            .dir
            .join(format!(".state-{}.tmp", uuid::Uuid::new_v4()));
        std::fs::write(&tmp, serde_json::to_vec(state)?)?;
        std::fs::rename(tmp, self.dir.join("state.json"))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn dir() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("renga-state-{}", uuid::Uuid::new_v4()))
    }
    #[test]
    fn credential_encoding_is_exact_and_canonical() {
        let valid = URL_SAFE_NO_PAD.encode([7_u8; 32]);
        assert!(canonical_credential(&valid));
        assert!(!canonical_credential(&(valid + "=")));
        assert!(!canonical_credential(&URL_SAFE_NO_PAD.encode([7_u8; 31])));
    }
    #[test]
    fn identity_persists_and_corruption_fails_closed() {
        let d = dir();
        let (s, a) = Store::open(&d).unwrap();
        drop(s);
        let (_, b) = Store::open(&d).unwrap();
        assert_eq!(a.private_key, b.private_key);
        drop(b);
        std::fs::write(d.join("state.json"), b"bad").unwrap();
        assert!(Store::open(&d).is_err());
        std::fs::remove_dir_all(d).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn rejects_state_and_directory_symlinks() {
        use std::os::unix::fs::symlink;
        let d = dir();
        let target = dir();
        std::fs::create_dir(&target).unwrap();
        std::fs::set_permissions(&target, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .unwrap();
        symlink(&target, &d).unwrap();
        assert!(Store::open(&d).is_err());
        std::fs::remove_file(&d).unwrap();
        let (s, _) = Store::open(&d).unwrap();
        drop(s);
        std::fs::remove_file(d.join("state.json")).unwrap();
        symlink("missing", d.join("state.json")).unwrap();
        assert!(Store::open(&d).is_err());
        std::fs::remove_dir_all(d).unwrap();
        std::fs::remove_dir(target).unwrap();
    }
}

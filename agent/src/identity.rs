//! Durable installation identity owned by the agent, not operator configuration.

use std::{fmt, fs, io::Write, path::Path};

const IDENTITY_FILE: &str = "installation-id";

#[derive(Debug)]
pub struct IdentityError(String);

impl fmt::Display for IdentityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for IdentityError {}

/// Reads the persisted UUID or creates it once. An explicit UUID is retained
/// only as a migration aid and is persisted before it is used.
pub fn load_or_create(
    state_directory: &Path,
    explicit: Option<&str>,
) -> Result<uuid::Uuid, IdentityError> {
    load_or_create_with_before_persist(state_directory, explicit, || {})
}

fn load_or_create_with_before_persist(
    state_directory: &Path,
    explicit: Option<&str>,
    before_persist: impl FnOnce(),
) -> Result<uuid::Uuid, IdentityError> {
    prepare_state_directory(state_directory)?;
    let path = state_directory.join(IDENTITY_FILE);
    let explicit = explicit.map(parse_uuid).transpose()?;

    if path.exists() {
        let persisted = read_identity(&path)?;
        if explicit.is_some_and(|value| value != persisted) {
            return Err(IdentityError(
                "installation_id does not match the persisted installation identity".into(),
            ));
        }
        return Ok(persisted);
    }

    let candidate = explicit.unwrap_or_else(uuid::Uuid::new_v4);
    before_persist();
    persist_new_identity(state_directory, &path, candidate)?;
    read_identity(&path)
}

fn parse_uuid(value: &str) -> Result<uuid::Uuid, IdentityError> {
    uuid::Uuid::parse_str(value).map_err(|_| IdentityError("installation_id must be a UUID".into()))
}

fn prepare_state_directory(path: &Path) -> Result<(), IdentityError> {
    fs::create_dir_all(path).map_err(|error| {
        IdentityError(format!(
            "cannot create state directory {}: {error}",
            path.display()
        ))
    })?;
    let metadata = fs::metadata(path).map_err(|error| {
        IdentityError(format!(
            "cannot inspect state directory {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.is_dir() {
        return Err(IdentityError(format!(
            "state directory {} is not a directory",
            path.display()
        )));
    }
    set_mode(path, 0o700)
}

fn read_identity(path: &Path) -> Result<uuid::Uuid, IdentityError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        IdentityError(format!(
            "cannot inspect installation identity {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.file_type().is_file() {
        return Err(IdentityError(format!(
            "installation identity {} is not a regular file",
            path.display()
        )));
    }
    set_mode(path, 0o600)?;
    let value = fs::read_to_string(path).map_err(|error| {
        IdentityError(format!(
            "cannot read installation identity {}: {error}",
            path.display()
        ))
    })?;
    parse_uuid(value.trim()).map_err(|_| {
        IdentityError(format!(
            "installation identity {} does not contain a UUID",
            path.display()
        ))
    })
}

fn persist_new_identity(
    state_directory: &Path,
    path: &Path,
    identity: uuid::Uuid,
) -> Result<(), IdentityError> {
    let temporary = state_directory.join(format!(".installation-id-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = create_private_file(&temporary)?;
        writeln!(file, "{identity}").map_err(|error| {
            IdentityError(format!("cannot write installation identity: {error}"))
        })?;
        file.sync_all().map_err(|error| {
            IdentityError(format!("cannot sync installation identity: {error}"))
        })?;

        match fs::hard_link(&temporary, path) {
            Ok(()) => sync_state_directory(state_directory),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(error) => Err(IdentityError(format!(
                "cannot persist installation identity {}: {error}",
                path.display()
            ))),
        }
    })();
    let _ = fs::remove_file(temporary);
    result
}

#[cfg(unix)]
fn sync_state_directory(path: &Path) -> Result<(), IdentityError> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            IdentityError(format!(
                "cannot sync state directory {}: {error}",
                path.display()
            ))
        })
}

#[cfg(not(unix))]
fn sync_state_directory(_path: &Path) -> Result<(), IdentityError> {
    Ok(())
}

fn create_private_file(path: &Path) -> Result<fs::File, IdentityError> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path).map_err(|error| {
        IdentityError(format!(
            "cannot create installation identity {}: {error}",
            path.display()
        ))
    })
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<(), IdentityError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(|error| {
        IdentityError(format!(
            "cannot protect installation state {}: {error}",
            path.display()
        ))
    })
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<(), IdentityError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    fn state_directory() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("renga-identity-{}", uuid::Uuid::new_v4()))
    }

    #[test]
    fn generates_once_and_reuses_identity_after_restart() {
        let state = state_directory();
        let first = load_or_create(&state, None).unwrap();
        let second = load_or_create(&state, None).unwrap();

        assert_eq!(first, second);
        assert_eq!(
            fs::read_to_string(state.join(IDENTITY_FILE))
                .unwrap()
                .trim(),
            first.to_string()
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&state).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(state.join(IDENTITY_FILE))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn separate_stateless_clones_generate_distinct_identities() {
        let first_state = state_directory();
        let second_state = state_directory();

        let first = load_or_create(&first_state, None).unwrap();
        let second = load_or_create(&second_state, None).unwrap();

        assert_ne!(first, second);
        fs::remove_dir_all(first_state).unwrap();
        fs::remove_dir_all(second_state).unwrap();
    }

    #[test]
    fn persists_migration_override_and_rejects_later_mismatch() {
        let state = state_directory();
        let explicit = uuid::Uuid::new_v4();

        assert_eq!(
            load_or_create(&state, Some(&explicit.to_string())).unwrap(),
            explicit
        );
        assert_eq!(load_or_create(&state, None).unwrap(), explicit);
        assert!(load_or_create(&state, Some(&uuid::Uuid::new_v4().to_string())).is_err());
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn concurrent_different_migration_overrides_cannot_both_succeed() {
        let state = state_directory();
        let barrier = Arc::new(Barrier::new(2));

        let workers = [uuid::Uuid::new_v4(), uuid::Uuid::new_v4()].map(|explicit| {
            let state = state.clone();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                load_or_create_with_before_persist(&state, Some(&explicit.to_string()), || {
                    barrier.wait();
                })
            })
        });

        let results = workers.map(|worker| worker.join().unwrap());

        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(results.iter().filter(|result| result.is_err()).count(), 1);
        fs::remove_dir_all(state).unwrap();
    }
}

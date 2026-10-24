# Organization export format

An organization export ([RFD 20](https://github.com/renga-dcim/rfd/blob/main/rfd/0020/README.adoc))
is one zstd-compressed tar file, conventionally named `<slug>.tar.zst`. This
document describes format version 1. `Renga.Transfers.Archive` reads and
writes it.

## Files

The tar holds regular files only, all at the top level:

- `manifest.json`, always first;
- one `<record_type>.ndjson` file per record type, where the record type
  matches `[a-z][a-z0-9_]{0,62}`.

No other entry may appear: no directories, links, or nested paths, and no
file twice.

Each `.ndjson` file holds one JSON object per line, each line ending in a
newline (`\n`), including the last. An empty file means the organization has
no records of that type. Numbers keep their full precision: decimal values are
written as JSON numbers, never as floats.

## Manifest

```json
{
  "format": "renga-organization-export",
  "format_version": 1,
  "renga_version": "0.1.0",
  "organization": {
    "id": "6f1d5c0e-4c69-4a8a-9b65-2b4c1f0e9a11",
    "slug": "acme",
    "name": "Acme"
  },
  "snapshot_at": "2026-10-22T19:00:00.000Z",
  "parts": [],
  "files": {
    "resources.ndjson": {
      "sha256": "<lowercase hex SHA-256 of the file>",
      "records": 1204,
      "bytes": 981233
    }
  }
}
```

- `format_version` changes whenever an exported record's shape changes. A
  release reads archives of its own format version and converts older ones
  through `Renga.Transfers.Converters`, one converter per earlier version;
  it refuses archives from newer releases. Every format version has a
  round-trip fixture in `test/fixtures/transfers/`, which each release must
  import, so a change that would break older archives fails until it comes
  with a new version and a converter.
- `renga_version` is the release that wrote the archive, for people; readers
  go by `format_version`.
- `organization` is the source organization. It is informational: an import
  always targets the organization the importer chose.
- `snapshot_at` is when the consistent snapshot was taken (UTC, ISO 8601).
- `parts` lists the optional parts included: `history` and
  `raw_observations`.
- `files` lists every record file in the archive with its checksum, record
  count, and size in bytes. The archive must hold exactly these files.

## Records

`Renga.Transfers.RecordTypes` is the authoritative list of record types and
their fields for this format version. Each record type is one kind of
organization-owned record, such as `resources`, `cables`, or
`organization_memberships`, exported with an allowlist of its fields. Records
never carry their organization's ID. A test fails until every column of every
organization-owned table is either exported or excluded with a reason, so a
new column never reaches an archive by accident.

Values are encoded as follows:

| Value | JSON |
| --- | --- |
| IDs, text, addresses, prefixes, MAC addresses | string |
| integers and decimals | number, at full precision |
| timestamps | string, ISO 8601 UTC with microseconds, such as `2026-10-22T19:00:00.123000Z` |
| binary values, such as an installation key's public key | string, base64 |
| JSON values | as stored |
| lists | array |
| absent values | `null` |

Two record types are special:

- `organization` holds one record: the organization's name, slug, and
  portable settings. Its status and ID are the destination's.
- `principals` holds one record per person the other records name, with
  `id` and `email`. An account without a global email (RFD 15) is named by
  the address one of the organization's own identity providers verified;
  `email` is `null` once the account was deleted or when there is no such
  address. Fields that name a
  person, such as `organization_memberships.user_id` or
  `change_events.actor_user_id`, hold a principal ID. A principal ID is the
  source deployment's user ID and means nothing in another deployment: an
  import maps principals to destination accounts, never by ID.

Organization-owned records keep their IDs, and every reference between them
stays inside the archive. Record types are listed in dependency order, so an
importer can insert them in that order; a few deferred fields, such as a host
source's `agent_id`, close a cycle and are set once both records exist.

### Parts

- Current state is always exported. It includes the observations that current
  evidence and identifier claims point at, with the reports they were split
  from, so an import reconciles the same way.
- `history` adds Activity (`change_events`), `resource_revisions`, `jobs` and
  `job_events`, `cable_change_events`, and `module_installation_events`, and
  the observations they point at. An owner's export from Settings holds a
  query job's parameters, result, and agent reports only when the owner may
  read them (RFD 12); otherwise `parameters` is `{}`, `result` is `null`, and
  the reports' `payload` is `{}`. An operator's export holds them all.
- `raw_observations` adds every other observation still within retention.

### Excluded

An archive never holds a credential: no password hash, passkey, authenticator
secret, recovery code, session, token, intake key hash, or job lease, report,
or offer credential. It also leaves out deployment configuration (identity
providers, limits, the operator audit log), pending invitations, agent leases,
and rows that triggers maintain from other records.

## Reading limits

Renga validates an archive completely before it imports anything. Beyond the
rules above, it refuses an archive that exceeds any of these limits:

| Limit | Default |
| --- | --- |
| Compressed size | 2 GiB |
| Expanded size | 16 GiB |
| Files | 256 |
| Records, across all files | 50,000,000 |
| One record (line) | 16 MiB |
| Manifest | 1 MiB |

Once the container is sound, `Renga.Transfers.Validation` checks what the
records say, against the record types above and this release's database
schema:

- the archive holds exactly the record files its parts call for, including
  `organization` (one record, matching the manifest) and `principals`;
- every record has exactly its type's fields, and each value is of its
  column's type, within its length or range, and not `null` where the column
  requires a value;
- no two records of a type share an ID;
- every reference names a record the archive holds. Where the database pairs
  fields in one reference, such as an evidence row's `observation_id` and
  `source_id`, they must match the same record. Every field that names a
  person names a principal.

A reference to a record outside the archive, including another
organization's, is a problem, so a valid archive cannot reach beyond the
organization it describes. Rules the database checks when records are
inserted, such as allowed status values, are left to the import, which
lands whole or not at all.

Validation reports up to 100 problems, each naming the file and line where it
can.

## Importing

`Renga.Transfers.Import` writes a valid archive into an organization that is
still empty, in one transaction: either every record lands or nothing does.
Records keep their IDs and timestamps, so an import is refused while any of
its IDs exists in the deployment, unless the importer asks for a copy
(`renga-admin import --copy`). A copy gives every record a new ID and
rewrites every ID column and every ID inside a JSON value to match, and the
source organization's ID becomes the destination's; links to the source's
records do not carry over. Either way, the import holds the organization so
that every other write to it waits, and at the destination:

- resource revisions and cable and module event sequence numbers are
  allocated again, in the source's order;
- each principal becomes an imported principal. Person fields are left empty
  and the principal they named is recorded beside them, or in the record's
  own principal column where the record must name someone. Imported
  Activity is marked as imported and names the person's email;
- memberships, team memberships, role assignments, and private saved views
  wait for their person to be linked;
- intake keys arrive revoked, approved installation keys pending, and active
  bindings revoked, so people at the destination approve each again;
- jobs are history: they never lease, retry, or run, and nothing can change
  them;
- portable settings apply unless they would allow more than the destination
  does now; those are held on the import for an owner to confirm. A security
  setting applies only when it adds a requirement, such as requiring MFA,
  and the destination's Activity records it as turned on by the import; a
  security setting that would lift a requirement is held under `security`.
  Owners confirm or dismiss held settings in Settings → Import.

### Bringing people back

`Renga.Transfers.Principals` invites an imported principal back to the email
address the archive had for it. Only a principal whose held membership was
active and manual can return (a membership a SCIM directory managed is
exported with `metadata.managed_by` set, and only the destination's own
directory grants it again), and it returns with that membership's role, which must be
within what the inviter may grant. Accepting needs an account that has
confirmed that address, and in one transaction it:

- links the principal to the account and restores the membership with its
  held ID;
- restores the membership's team memberships, and its manual role assignments
  that are still valid and within what the inviter may grant;
- restores the principal's private saved views as the account's own;
- fills the empty person fields of current records the principal was
  attributed with.

Whatever does not apply stays held. History (Activity, job events, cable and
module events, jobs) and cable claims keep their imported attribution.

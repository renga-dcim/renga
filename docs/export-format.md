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
  release reads archives of its own format version and converts older ones;
  it refuses archives from newer releases.
- `renga_version` is the release that wrote the archive, for people; readers
  go by `format_version`.
- `organization` is the source organization. It is informational: an import
  always targets the organization the importer chose.
- `snapshot_at` is when the consistent snapshot was taken (UTC, ISO 8601).
- `parts` lists the optional parts included: `history` and
  `raw_observations`.
- `files` lists every record file in the archive with its checksum, record
  count, and size in bytes. The archive must hold exactly these files.

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

Validation reports up to 100 problems, each naming the file and line where it
can.

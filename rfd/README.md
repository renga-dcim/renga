# Renga Requests for Discussion

Requests for Discussion (RFDs) capture ideas early enough to shape them through
written discussion and preserve the reasoning behind decisions. An RFD is not
authoritative merely because it exists; its `state` says how it should be read.

| RFD | Topic |
|---|---|
| [1: Renga DCIM architecture](0001/README.adoc) | Product principles, inventory model, collection, reconciliation, and control-plane direction |
| [2: DCIM host agent MVP](0002/README.adoc) | The first complete host collection, reconciliation, and inventory UI loop |
| [3: Organization intake keys](0003/README.adoc) | Shared organization intake credentials and automatic collector registration |
| [4: IP address management](0004/README.adoc) | VRFs, managed prefixes and addresses, observed assignments, utilization, and conflict detection |
| [5: Physical containment](0005/README.adoc) | Sites, nested locations, racks, placement, occupancy, and placement evidence |
| [6: Hardware catalog and components](0006/README.adoc) | Manufacturers, reusable types, expected components, observed hardware, modules, and inventory items |
| [7: Layer 2 topology and VLANs](0007/README.adoc) | VLAN namespaces, interface membership, observed adjacency, reconciled links, and physical cables |

## Source format

Each RFD lives at `rfd/NNNN/README.adoc`, where `NNNN` is a four-digit number.
The document starts with canonical AsciiDoc attributes and an unpadded title:

```asciidoc
:authors: Name <email@example.com>
:state: prediscussion
:discussion:
:labels: software, process

= RFD 5 Example title
```

`authors` contains semicolon-separated owners. `discussion` contains the RFD's
pull-request URL once discussion starts. `labels` is a comma-separated set of
searchable topics. The document is the single source of truth for this metadata;
the index intentionally does not duplicate it.

Implementation progress lives separately in `rfd/NNNN/IMPLEMENTATION.org`. The
checker also accepts `IMPLEMENTATION.md`; an RFD must have exactly one format.
The RFD and checklist link to each other, keeping design and decision history
stable while implementation tasks are checked off.

Run `make check-rfds` to validate source layout, metadata, state, title, and the
checker regression fixtures. CI also supplies `RFD_BASE_REF` so the checker can
reject lifecycle regressions, historical deletion, and changes to final RFDs
against the pull-request or push base. A local review can do the same with
`RFD_BASE_REF=<git-revision> make check-rfds`.

## States

- `prediscussion`: actively being written and not ready for broad review.
- `ideation`: a narrowly scoped topic or scratchpad without active revision.
- `discussion`: under active review in the linked pull request.
- `published`: discussion has converged and the RFD expresses project direction.
- `committed`: the proposal is fully implemented and describes current behavior.
- `abandoned`: deliberately not proceeding or retained only for history.

The usual path is `prediscussion` or `ideation` to `discussion`, then
`published`, and eventually `committed`. `abandoned` is an off-ramp before a
final state.

Checklist progress never changes state automatically, but `committed` requires a
non-empty checklist with every task complete.

`prediscussion` and `ideation` may move between each other or advance to any
later state. `discussion` may advance to `published`, `committed`, or
`abandoned`; `published` may advance to `committed` or `abandoned`. Published and
committed decisions never regress to drafting states. A committed or abandoned
RFD is immutable: replace or supersede it with another RFD rather than rewriting
its lifecycle.

## Lifecycle

Reserve the next unused four-digit number and create `rfd/NNNN/README.adoc` and
one implementation checklist (`IMPLEMENTATION.org` or `IMPLEMENTATION.md`) on a
branch. Cross-link the two documents. Use `prediscussion` while writing or
`ideation` for a topic placeholder. When the document is ready for review, open
a pull request, set the state to `discussion`, and add that pull request as the
discussion URL.

Before merging a proposal that represents project direction, move it to
`published`. Once the described work is entirely implemented, update it to
`committed`. Material changes to a published or committed RFD go through a new
pull request and retain the original discussion link unless the RFD explicitly
documents a replacement. Changes that supersede a committed or abandoned RFD use
a new RFD and cross-link the historical decision.

## Shared principles

- Context functions enforce authorization; hiding a control in the UI is never
  an authorization boundary.
- Every user-facing query is scoped to the current organization in the database.
- Browser routes requiring login use the existing authenticated router scope and
  LiveView session. Machine APIs use narrowly scoped bearer authentication.
- Raw observations remain immutable; processing and reconciliation state live in
  separate records.
- Canonical inventory remains source-neutral while retaining per-source evidence.
- Desired state, observed facts, and manual corrections remain distinct.
- Stable, frequently queried inventory uses typed PostgreSQL projections; JSONB
  is reserved for variable desired state, detailed evidence, and vendor data.

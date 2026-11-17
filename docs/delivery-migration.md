# File delivery migration and coverage handoff

work-pim moves delivery planning to the host. The user explicitly approved
replacement of batching, fan-out, continuation and failure-policy assertions
in the implementation conversation. The provider tests retain metadata,
identity, redaction, caption, restored-handle and single-message lifecycle checks.
No ZAQ planner/executor or Agent validation changes are included here.

| Previous provider scenarios | Provider contract now tested | Required future host coverage |
| --- | --- | --- |
| `attachment_policy_test.exs`: abort uploads every group before publication; continue keeps usable uploads; all failed uploads publish text | Retired policy rejected on send/file/post/edit and restored handles; upload errors publish nothing | ZAQ `attachment_policy_test.exs`: stop/continue policy, all-failed text choice, strict upload preparation before first publication |
| `attachment_policy_test.exs`, `attachment_failure_coverage_test.exs`: partial upload prefixes and failed later groups | Complete one-request identity confirmation; retired partial results cannot publish an inferred prefix; safe neutral errors | Host records each explicit upload result, reuses confirmed references and accounts for pending/unconfirmed operations without retrying |
| `attachment_preflight_report_test.exs`: rejected files and valid siblings receive per-file report outcomes | Any rejected sibling prevents the complete selection from uploading or publishing | Host owns per-file rejection records, unattempted siblings and policy choice before materialization |
| `attachment_edit_test.exs`: 15 files form 10+5 posts; 25 files stop after a failed later post | More than ten files rejects before any upload or post; an edit never creates additional posts | ZAQ `jido_chat_delivery_test.exs`: file grouping, partial publication and separate confirmed history records |
| `attachment_edit_test.exs`: generated captions and continuation root selection across post/edit, restored state, atom/string roots and explicit/omitted roots | Requested post/edited ID remains the only handle; returned server root is retained, no continuation publication | Host continuation captions and routing: explicit empty root, nonempty server root, omitted root with saved hint; repeat after restore |
| `attachment_edit_test.exs`: first-post attachment membership after split/rejected deliveries | Single-message attachment snapshots follow provider IDs/order; sparse details only match known IDs; explicit removal and restored handles retained | Host records each message's attachments independently and never combines continuation attachments into the first handle |
| `attachment_edit_test.exs`: edit clears old partial report | Synthetic pre-migration handle fixture verifies stale report invalidation before/after JSON restore | Host migrates persisted policy/report state and preserves authoritative latest snapshots |
| `transport/req_client_test.exs`: exact-limit files automatically upload in several HTTP requests | Pure exact candidate, equality/one-byte-over bounds, explicit upload with ordered identities, retry disabled | Host chooses upload candidates from independent per-file, per-post and encoded-request constraints |

The existing suites were extended or replaced in place; no assertions were
silently skipped. The obsolete policy-only transport fixture was removed.
`attachment_failure_coverage_test.exs` still exercises transport exceptions,
exits, unknown-error redaction, alternate confirmed upload shapes, missing
sources and no fallback publication. `attachment_edit_test.exs` retains the
pre-existing retained/replaced/removed/sparse attachment regression tests.

## Dependency adoption

Mattermost pins the supporting immutable SDK revision in `mix.exs` and
`mix.lock`. Consumers overriding `jido_chat` must use that revision or a
compatible revision containing the public file-operation contracts. Pin the
published Mattermost revision as well; a lockfile-only change cannot override a
fixed dependency ref in the consuming application's `mix.exs`.

SDK review also fixed retained `uploaded_files` defaults: subsequent text edits
must not reattach removed references. Explicit reference publication now requires
`uploaded_files: :native`, and reference edits require attachment-edit support,
preventing unsupported adapters from silently discarding references.

Old ZAQ policy/report consumption needs its separately planned host migration.
Record exact failing consumer paths before claiming dependency adoption passes.

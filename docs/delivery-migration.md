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
| `transport/req_client_test.exs`: exact-limit files automatically upload in several HTTP requests | Pure exact candidate and byte measurement, explicit upload with ordered identities, retry disabled | Host chooses upload candidates from per-file and per-post constraints; an encoded-request constraint applies only when the provider declares one |

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

## work-pim.7 request-size correction

This correction supersedes the earlier requirement for a separately configured
upload-request ceiling. `file_requirements/1` returns
`%{max_file_size: limit_or_unresolved, max_files_per_post: 10,
max_upload_request_size: :not_applicable}`. The request field is retained solely
for the existing generic SDK contract; Mattermost does not read or enforce the
former option or application setting. The SDK revision
`f17679337a9975bee43b9540cb08ac5cfc12b86a` already accepts `:not_applicable`.
No SDK change or consumer-specific sentinel is needed.

`max_file_size` remains mandatory for new file delivery and preparation; opts
override application configuration. Missing/invalid values and oversized actual
bytes still fail before upload. Post creation/edit still accepts at most ten
files. Exact multipart bytes, content type, byte count and input metadata remain
available. Each `upload_prepared/2` invocation submits that binary in one HTTP
attempt with retries and redirects disabled. Provider failures remain errors;
there is no automatic split, retry, text fallback or policy orchestration.

Existing test expectations changed in place: requirements no longer report an
unresolved/configured request ceiling; exact-limit and header-heavy rejection
checks now verify full encoding/measurement without a ceiling; request-config
errors now verify ignored legacy configuration and continued transport errors.
Per-file, malformed-candidate, identity, redaction and no-fallback checks remain.
The real-client integration options no longer supply the former setting.

ZAQ counterpart: `zaq-1lw.17` in `../zaq-feat-channel-files`. ZAQ owns
normalization of the standard SDK requirements and final host integration
validation. This issue does not modify ZAQ. Its dependency must eventually pin
the published revision containing this correction in both `mix.exs` and
`mix.lock`; base revision `73b7e10f44e14bf8b7774d584d88c29332f7a49f` alone does
not contain it. The workspace-planning handoff records validation results and
the corrected revision for dependency adoption.

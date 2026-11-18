# Resume after an interrupted job

A restarted engine reports an unfinished job as **Didn't finish**. Startup does
not restart that job or call its model or tools. Scheduled runs remain a separate
feature controlled by the person's existing schedules switch.

**Resume** is offered only when the engine validates a complete checkpoint from
the read-only prefix of that same run. It is a separate action from **Continue
fresh**. Continue starts another run from the job's folder, can repeat earlier
actions, and can reuse the job's existing browser grants.

Resume discards the incomplete live batch and can ask the model again. It does
not promise the same model reply. Every new gated action asks afresh. The Resume
confirmation card in the job row shows read sites and act sites separately with no sites preselected. The
engine accepts only confirmed subsets of the stored scope, tied to the job, run
and current recovery generation. Old approval identifiers confer no authority.

## When Resume is unavailable

Resume is unavailable after any possible effect has been dispatched, including
an error, refusal or cancellation returned by that dispatch. A successful result
does not make that run eligible again. Shell commands and unknown tools are not
classified as read-only. Opening a signed-in browser page, looking at browser
controls, browser actions, screen sequences and drives are outside this initial
read-only contract.

An unresolved model call, including a wrap-up call, prevents Resume. Missing,
corrupt, oversized, legacy or incompatible authority, unknown continuation
fields, incomplete checkpoints, images, reasoning and credential-shaped content
fail closed. Providers that require replayed reasoning or whose neutral
continuation has not been audited are ineligible. Current policy still restricts
every offered and dispatched tool.

## Stored data and lifecycle

The private `jobs/<id>.recovery.json` envelope sits beside the job record, outside
its model-accessible folder. The existing private-path rules cover it and its
fixed temporary name. It contains only validated neutral messages and explicit
continuation state, never a serialized provider, provider credentials, session
objects, usage tokens, images or reasoning. Text tool results can contain sensitive
user data. The envelope and temporary file use owner-only permissions.

The envelope has an exact schema, source compatibility fingerprint, job/run and
generation identity, integrity digest, cumulative limits and taint, and a complete
checkpoint. Writers serialize updates. File flush, fsync, atomic replacement and
directory fsync order the authority before a model call or possible effect. A
failed authority write stops that action. This is a process-crash recovery
contract. Sudden hardware power loss has not been verified or promised.

A normal finish, user Stop, explicit cancellation or ordinary failure removes
checkpoint text. Irreversible effect markers remain for that run. A fresh
Continue invalidates the old authority before starting another run. The job store's delete
operation removes the ended job's folder, record, schedule and recovery envelope.
It refuses queued or running records. Clear only hides the
row and does not delete the job or its data.

## Offline verification

`tests/check_recovery.py` drives real disposable files and separate engine
processes with a fake provider. It kills processes around checkpoint, model,
read-result, partial-batch, approval, effect-dispatch and effect-result boundaries.
It checks explicit Resume, startup inactivity, stale consent and approval
rejection, cumulative limits/taint, restricted grants, invalid storage, failed
writes and private content omission. The main engine selftest includes these
checks. Swift tests cover snapshot defaults, protocol fields, wrapper forwarding,
consent validation and capability negotiation with stand-in engines. ServeCheck
runs the real Swift backend against an engine and offline HTTP fake model.

These checks exercise process crashes, not power failures, a live provider,
real Chrome, or the visible consent card. No macOS permission grant is needed.

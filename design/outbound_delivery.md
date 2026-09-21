# Outbound delivery: deliverable addresses, delivery notices, and a sent ledger

Status: shipped. The transport-neutral delivery notice, the `chat sent`
ledger over a `deliveries.jsonl` index (`bin/chat`), the "Sent in the
last 24h" wake prompt section (`_outbound_section` in
`thinkers/_lib/common.sh`, wired in `thinkers/monolith/step`, rule in
`prompt.md`), and send-time dedup with `--force` in `chat send` and
proactive `chat reply` are all built and tested, with the Telegram
bridge as the transport that writes notices
(`telegram/src/headlong_telegram/outbound.py`). Tests:
`tests/test_chat_sent.sh`, `tests/test_monolith_wake_sections.sh`,
`telegram/tests/test_outbound.py`. The phone chat has no bridge process, so
its sends show as `unconfirmed` rather than `delivered` or `failed` (see
part 7). Deploy restarts the bridge through deploy/update.sh; `chat`,
`_lib`, and the monolith prompt reach Audel through the thinker sync.

Related: [conversation_memory.md](conversation_memory.md) part 5 is the
deferral index this design copies. [monolith_thinker.md](monolith_thinker.md)
covers the recent stream the monolith reads. [trajectory_spec.md](trajectory_spec.md)
is the step registry the new step type joins.

## The problem

An outbound message is an intention the mind writes down, not an act it can
see the result of. `chat send` appends a `message` step and exits 0. A bridge
process later reads that step and either posts it or does not, and nothing
comes back either way. The mind's only record that it spoke is its own
message step, and its only way to notice that it already spoke is to find
that step in the last 20 durable steps of its recent stream.

Both halves failed in the same week.

**Silent drops.** A transport drops anything whose `to` its own grammar
does not parse. On 2026-09-05 to 09-09 Audel addressed 23 of 74 sends to
bare ids the then-live grammar rejected, including most of the daily
papers posts and four DMs to Nick. None reached anyone, and the bridge
journal had zero warnings: a malformed `to` hit a bare `continue`. The
lesson holds for any transport — a name the bridge cannot decode is a
message that vanishes — and the fix is the same everywhere: a `failed`
delivery notice instead of silence. Today a `telegram-*` `to` that fails
`naming.is_telegram_name` gets a `failed` notice naming the reason, and
`chat sent` shows it. Audel's own memories from 2026-08-04 and 08-05
describe this exact rule and a box-side fix that never reached main.

**Forgotten sends.** On 2026-09-08 Audel sent the same two papers four times
between 22:21 and 01:06 UTC. Between the first send and the second run's
prompt there were 16 idle runs, each adding an idle step and a final, so the
20-step window covered only 22:38 to 22:54 and the send had scrolled out.
The idle finals also repeated the stale plan ("queued Dr. Claw and RISE for
the 00:00 window"), reinforcing it. The fourth run tried to check with
`traj search`, which was killed by timeout on the 136K line log, and sent
anyway.

The responder's deferral index (conversation_memory.md part 5) already solves
the same shape of problem for inbound requests. A request is a structured
step, it is indexed over the whole trajectory, it is resolved by an explicit
marker, and the wake prompt lists the open ones however many steps have piled
on top. This design applies that shape to outbound messages.

## Design

### 1. Address grammar, in one place

`telegram/src/headlong_telegram/naming.py` owns the grammar. It accepts one
form:

| form | meaning | delivery |
|------|---------|----------|
| `telegram-<user id>-<chat id>` | a DM with that user | `sendMessage` to the chat id |

The two ids are what the mind writes when it means "DM Nick in Telegram";
the bridge then does what was meant. The bridge is DM only, so both ids are
positive integers; group chat ids are negative, and `encode()` refuses them
outright because their leading minus would break the `-` separator.

The grammar ships as a function (`naming.is_telegram_name`) in the bridge
project only. The old design kept transport grammar mirrored by a regex
copy in `bin/chat`, pinned equal to the bridge's by a cross-file test;
that copy is gone with the transport it belonged to, so there is no mirror
between `chat` and the bridge to keep in sync anymore. The bridge is the
single owner of the grammar and the single checkpoint that turns a bad
address into a `failed` notice.

### 2. The bridge writes a delivery notice for every send

After handling a `message` step addressed to a `telegram-*` name, the
bridge appends one step to the root trajectory:

```json
{"type": "delivery", "source": "telegram-bridge", "transport": "telegram",
 "trigger_step": "<message step_id>", "to": "telegram-8525624593-8525624593",
 "status": "delivered", "chat": "8525624593",
 "content": "delivered to telegram-8525624593-8525624593"}
```

or, on failure,

```json
{"type": "delivery", "source": "telegram-bridge", "transport": "telegram",
 "trigger_step": "<message step_id>", "to": "telegram-bogus",
 "status": "failed", "reason": "unknown telegram address form; accepted: telegram-<user id>-<chat id>",
 "content": "not delivered to telegram-bogus: unknown telegram address form; accepted: telegram-<user id>-<chat id>"}
```

Rules:

- `trigger_step` is the message step the notice is about, following the
  registry convention. A later reader resolves a send by matching it.
- The bridge writes the step by running `bin/traj append` on the identity's
  root trajectory, the same lock every other writer uses. It never opens the
  file for writing itself. Before spawning traj it checks that the
  trajectory and its directory are writable, and after one `PermissionError`
  it disables notices for the run with a single log line — the Telegram
  bridge runs as a user with read-only access to the log, and its first
  notices each hung for the full subprocess timeout instead of failing (the
  2026-09-09 incident below).
- A `to` that starts with `telegram-` but fails the grammar gets a failed
  notice (`unknown telegram address form`), as do an unapproved recipient
  and a group chat. A `to` for another transport is skipped, silently,
  because that transport's bridge owns it.
- Text posts and file uploads get notices. Reactions do not; they are not
  sends the mind needs to account for.
- The notice is keyed on the message step id. A bridge restart that replays
  a step writes a second notice for the same trigger, which readers treat as
  a duplicate, not a second delivery.
- The bridge already skips its own steps when following the log, because it
  only acts on `message` steps from the identity with `source: chat`.
- `transport` is the generic axis a reader keys on, `status` is
  `delivered`, `failed`, or `skipped`, `reason` names the failure, and
  transport-specific fields (`chat`, `permalink`, `message_ts`, `filename`)
  ride along where a transport has them. The Telegram bridge puts the
  numeric chat id in `chat`; it has no permalink concept, so it writes none.

### 3. Who wakes up, and who sees it

The dispatcher wakes thinkers by step type. The monolith subscribes to
`observation`, `action`, `merge`, and its own wake step; the responder
subscribes to `message`. `delivery` is subscribed by nobody, so a notice
never wakes anything and cannot form a send-notice-send loop. A notice
written as a `message` would have made the responder answer it, and one
written as an `observation` would have woken the monolith after every send.

Failed notices are added to the monolith's recent stream filter
(`_recent_stream` in `thinkers/_lib/common.sh`), so a failure is visible at
the next wake even before the ledger exists. Delivered notices are not; they
would double every send in a 20-step window and are the ledger's job.

Waking the monolith on a failure is left off. It can be turned on later by
adding `delivery` to the monolith's subscriptions once notices have been
watched for a while.

The mid-run injection the dispatcher does for inbound messages (a `feedback`
step appended while the monolith is busy) is not extended to notices. That
path has been dead since the monolith moved to run scope on 2026-09-03,
because the feedback step carries no run id and run scope keeps only rows
that do, and its purposes are now covered by the responder and the deferral.
Retiring it is a separate change.

### 4. The sent ledger

`chat sent [--since 24h] [--json]` lists the identity's outbound message
steps with their delivery state, newest first:

```
2026-09-08T22:21Z  telegram-bogus  failed (unknown telegram address form; accepted: telegram-<user id>-<chat id>)  "Daily Paper — Dr. Claw…"
2026-09-07T00:02Z  pwa-andy        unconfirmed  "Daily papers for 2026-09-07…"
2026-09-07T04:46Z  telegram-8525624593-8525624593  delivered  "Built a reaction-memory cross-check…"
```

It is built the way `chat pending` is built: a derived index next to the
trajectory, `deliveries.jsonl`, maintained in the same incremental pass as
`messages.jsonl` and `deferrals.jsonl`, holding every `delivery` step. The
join is by `trigger_step`: a send is `delivered`, `failed`, or `skipped`
when a notice with its step id exists, and `unconfirmed` otherwise — the
state before a bridge has reported, and the state a transport that never
reports (the phone chat) is always in. A send that has been `unconfirmed`
longer than a few minutes means the bridge for that transport is down or
behind, which nobody could see before.

The monolith's wake prompt gains a short section, rendered from
`chat sent --since 24h`, one line per send with the destination, the state,
and the first few words. It is keyed by time, not by step count, so it
survives any number of idle wakes. It costs a few hundred bytes on a busy
day and nothing on a quiet one.

### 5. Send-time dedup

`chat send` consults the same index and refuses to append a message whose
content matches one already sent to the same destination in the last 24
hours (`CHAT_REPEAT_WINDOW`), unless `--force` is given. The refusal names
the earlier send and points at `chat sent`. `chat reply` gets the same check
only when it answers nothing, i.e. no `reply_to` was given or inferred, which
makes it a proactive send into a conversation. A reply stamped to a specific
inbound is exempt, because two questions may deserve the same answer and the
responder must not be blocked from saying "still running" twice in a day. A
separate `--key` refusal (`_refuse_key`) names the one duty a send fulfils
and holds however the text is reworded, past the exact-text check below (on
2026-09-18 the same papers post went out five times in three hours, reworded
each time). The bridge's five-minute dedup stays as a backstop for a replayed
step. This moves the checks the mind failed to make on 2026-09-08 and
09-18 into the tool, so the mind does not have to remember to check.

### 6. Other transports

The Telegram bridge writes the same `delivery` step with `transport:
telegram` and `source: telegram-bridge`, including failed notices for an
address that is not on its allowlist or names a group chat. The phone chat
has no bridge process: the web server serves messages straight from the
trajectory when the phone polls, so there is no moment that means
"delivered" short of the phone acknowledging, which it does not do today.
Its sends are shown as `unconfirmed` (a transport that never reports back)
rather than `pending` (a bridge that has not reported yet), so a stale
phone-chat send does not read as a bridge outage. If the phone client ever
acknowledges, the web server can write the same step.

## Small changes shipped alongside (2026-09-09)

- The recent stream drops an idle run's final, so a string of idle wakes
  collapses to one "idle xN" line instead of two steps per wake
  (`_RECENT_STREAM_PAIR_JQ`). This does not replace the ledger; it keeps
  idle wakes from eating the window.
- The dispatcher's mid-run `feedback` injection is removed (dead since run
  scope; the responder and the deferral cover its jobs). The pending file
  handoff is unchanged.
- A monolith run that dies with no durable step now records the last stderr
  lines in its `error` step (`stderr_tail`), so bursts like 2026-09-07 have
  a reason attached.
- `traj search` prefilters rows with one grep and takes `--tail N`, so a
  self-check on a long log finishes instead of being killed by timeout.
- `mem add` rejects a flag it does not know instead of storing it as the
  memory's first word.

## Incident on the first day (2026-09-09) and what it changed

Switching the Telegram bridge back from a scratch identity to Audel at 10:55
UTC handed it a cursor written for the other trajectory (its state dir is
shared across identities). `follow` treated the small offset as valid and
read Audel's whole 1.5 GB log, so the bridge re-sent 65 historical Telegram
messages (08-06 to 08-12) to the three people on its allowlist before it
was stopped at 11:29. Each
send took 31 seconds because the notice writer ran `bin/traj append` as the
bridge user, which has read-only access to the trajectory, and traj's lock
loop spun for the whole subprocess timeout instead of failing. Three
changes:

- `mindlog.follow` writes `<offset> <trajectory path>` and ignores a cursor
  for any other trajectory; a shrunk file resumes at its end instead of
  replaying from zero. A bridge must never replay.
- The notice writer checks that the trajectory and its directory are
  writable before spawning traj, and after one `PermissionError` disables
  notices for the run with a single log line. `bin/traj append` dies at
  once when it cannot create its lock directory.
- Because the Telegram bridge user cannot write the log by design (it keeps
  the bot token out of the agent's reach), Telegram notices are off on the
  box and `chat sent` shows Telegram sends as `unconfirmed` there. Giving
  that user append rights on the trajectory, or routing the notice through
  the web API, would turn them on; neither is decided.

## What this does not do

- It does not give recurring goals a progress log. That is a separate design.
- It does not touch the run scope render.

## Rollout

The telegram transport was the whole rollout, in one deploy with a bridge
restart (deploy/update.sh already restarts the bridge unit):

1. `naming.py` grammar and `is_telegram_name`; tests for the one form.
2. `outbound.py`: write notices on every send, warn on bad addresses, fail
   on allowlist and group violations; tests with a fake bot
   (`telegram/tests/test_outbound.py`).
3. `bin/chat`: `chat sent` over `deliveries.jsonl`, the `--force` repeat and
   key refusals; a bash test (`tests/test_chat_sent.sh`).
4. `_recent_stream`: admit failed notices; a test.
5. `design/trajectory_spec.md`: register `delivery`.

Verification on the box after deploy: send one message to a real `telegram-*`
name from an identity shell and confirm it lands in Telegram with a
`delivery` step carrying `status: delivered`, then send one to a name that
fails the grammar (say `telegram-bogus`) and confirm a failed notice and a
journal warning. `chat sent --since 24h` from an identity shell should list
the day's sends with `delivered` beside the Telegram ones and the next wake
prompt should carry the "Sent in the last 24h" section (check a `prompt`
step).

## Open questions

- Should the phone chat ever acknowledge deliveries? A `unconfirmed` send
  cannot be told apart from a bridge outage today except by knowing the
  transport.
- Should a failed notice eventually wake the monolith? Off for now.
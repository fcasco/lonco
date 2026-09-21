# Security posture of the chat integrations

This doc summarizes how each way of talking to a Headlong identity is
secured. It covers the phone chat PWA (`web/`, served behind Cloudflare
Access) and the Telegram bridge (`telegram/`). Read
this before widening access to any of them.

## What both share

The identity is an agent that runs arbitrary bash on its box with its
API keys, and every message a person sends goes straight into the
agent's context. Prompt injection is therefore always possible, from any
channel, and the defenses are the same everywhere:

- The box is dedicated and burnable, with zero inbound network access.
  Both integrations dial out (a Cloudflare tunnel, and Telegram long
  polling), so nothing listens.
- The LLM key is dedicated to the box and spend capped.
- The box holds only the secrets it needs, because it allows all
  outbound traffic and an injected agent could send those secrets out.
- All conversations share one mind log. Anything one person tells the
  identity may surface in replies to anyone else, on any channel. Do
  not tell it secrets you would not post in a public channel.

Each channel is one message namespace in the mind log (`pwa-*`,
`telegram-*`). Each bridge only forwards replies addressed to
its own namespace, so the channels cannot leak into each other's
transport, though the shared mind means content can still cross.

Each bridge has a kill switch that mutes the channel without touching
the agent. For the phone chat it is disabling the Cloudflare Access
app, and for Telegram it is `systemctl stop headlong-telegram-bridge`.

## Runtime sandbox and the bridge tokens

Every wake runs inside `headlong-thinkers@<identity>.service`, and that
unit carries a sandbox drop-in (`deploy/thinkers-sandbox.sh`, on by
default, `HEADLONG_SANDBOX=0` in the root `.env` turns it off at the
next `headlong-thinkersctl restart`). Inside it the whole filesystem is
read-only except the shellm home (tool caches, state), the identity's
own directory (memories, prompts, thinker copies, workdir, its clone of
the repo), and `/tmp` and `/var/tmp`. The app checkout is read-only, so a
wake cannot edit `bin/`, `thinkers/`, `tools/`, `deploy/` or the root
`.env` in place, cannot create another identity beside its own. `sudo` stays limited to
the `headlong-thinkersctl` wrapper, as before, so a mind can still
restart itself the documented way. The rules apply to anything
the wake backgrounds too, because they are mount rules on the unit's
namespace, not checks in the tools. The mind keeps full sovereignty
over its own identity directory; contributions to the runtime go
through its clone and pull requests.

The Telegram bridge runs as its own user with its token in a root-owned
file (see below), so a wake cannot read it. The box alert scripts post
with `HEADLONG_ALERT_TOKEN` from the root `.env`, which the identity's
user can read — keep that a token with alert-only rights.

## Phone chat PWA

Who can talk to the identity. Only people who pass the Cloudflare Access
app in front of the chat domain. Access requires Google SSO or a one
time code, and the allowlist is the operator's email plus, optionally,
an email domain (`allowed_emails` / `allowed_email_domains` in the terraform
stack). A second, path-scoped Access app bypasses login only for the app
manifest and icons, which Android fetches without cookies during
install.

How it connects. The box reaches Cloudflare through an outbound tunnel.
Messages arrive over the same web API the bridges use, under `pwa-*`
sender names that no outbound bridge forwards.

Push notifications. The push subscription store and the VAPID keys live
on the box, and only `pwa-*` names can subscribe. The keys die with the
box, and phones resubscribe on the next launch.

Known gaps. If an email domain is allowed, anyone with an account in
that domain can reach the chat; that is the intended trust circle. The push files are readable by the
agent's user, but they only allow sending notifications to subscribed
phones, not reading anything.

## Telegram

Who can talk to the identity. Only users on the bridge's allowlist.
Anyone on Earth can message a Telegram bot, so the bridge drops unknown
senders before their text reaches the mind log, and it stays silent
toward them so probing the bot confirms nothing. The admin approves or
denies senders from their own Telegram chat, and gets at most one prompt
per unknown sender per day.

The allowlist gates both directions. Replies addressed to unapproved
users are dropped, so an injected agent cannot use the bridge to carry
data out to an arbitrary chat.

Scope limits. The bridge is DM only. It leaves any group it is added
to, because the allowlist cannot control who is in a group. Inbound
media is dropped, so nothing gets downloaded onto the box. Outbound
file steps (`chat send-file`) are uploaded as Telegram documents or
photos; that is agent-to-user, not a download path.

How it connects. The bridge long polls the Telegram API outbound. The
bot token lives in `/etc/shellm/telegram.env`, which is root owned with
mode 600, and only systemd reads it. The bridge runs as its own user
(`shellm-telegram`) rather than as the agent's user, because processes
with the same uid can read each other's environment. The allowlist and
cursors live in `/var/lib/shellm-telegram`, which the agent's user
cannot write, so an injected agent cannot approve an attacker.

Known gaps. The env file does not survive an instance rebuild and must
be recreated by hand. A leaked bot token would let an attacker
impersonate the bot to approved users and race the bridge for incoming
messages. Telegram bot chats are not end to end encrypted, so Telegram's
servers see all content. There is also a `skills/telegram` skill that
teaches the agent to drive the Telegram API with curl. Giving the agent
the bridge's bot token would undo the token isolation, so if the agent
should have Telegram access of its own, use a separate bot and token.

## Comparison

| | Phone chat PWA | Telegram |
|---|---|---|
| Gate | Cloudflare Access (SSO) | Bridge allowlist |
| Who holds the gate | Cloudflare config | Admin over Telegram |
| Secrets on box | VAPID keys | Bot token |
| Agent can read them | Yes (push files) | No (root-owned env, separate user) |
| Outbound reply check | Not needed (pull) | Allowlist |
| Survives rebuild | Keys regenerate | No (recreate env file) |
| Kill switch | Disable Access app | Stop bridge unit |
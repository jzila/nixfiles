"""Webhook script for the ha-maintenance route: Home Assistant -> kanban tasks.

Home Assistant posts the full current list of things of one kind that need
attention:

    {"kind": "zwave_battery",
     "devices": [{"name": "Foyer T/H", "battery": 5, "last_seen": "2025-08-23T07:07:54+00:00",
                  "issues": ["silent", "low"]}, ...]}
    {"kind": "client_cert",
     "devices": [{"name": "homeassistant.local.zila.dev", "expires": "2026-11-20T01:49:22+00:00",
                  "error": "...", "issues": ["renewal_failed"]}]}

The list is reconciled against the board, without the agent: one open task per
item on tenant "hass" (created if missing, its body refreshed if the issues
changed), and tasks for devices no longer listed are completed. Prints
[SILENT] so Hermes drops the webhook instead of starting an agent turn.

The payload is untrusted input; it only ever becomes task titles and bodies,
passed as argv (never through a shell).
"""
import json
import re
import subprocess
import sys

TENANT = "hass"
# kind -> (task title prefix, issue -> description)
KINDS = {
    "zwave_battery": ("Z-Wave battery", {
        "silent": "not heard from in 48+ hours",
        "low": "battery at or below 20%",
    }),
    "client_cert": ("Certificate renewal", {
        "renewal_failed": "automatic renewal at the step CA failed; it is retried daily until the certificate expires",
    }),
}
MAX_DEVICES = 200


def clean(text, limit):
    return re.sub(r"[^\w .,:()/'&+-]", "", str(text))[:limit].strip()


# Substituted by Nix with the store path of the hermes CLI.
HERMES = "@hermes@"


def kanban(*args):
    out = subprocess.run([HERMES, "kanban", *args], capture_output=True, text=True, timeout=20, check=True)
    return out.stdout


def main():
    payload = json.load(sys.stdin)
    payload = payload.get("payload", payload)
    kind = payload.get("kind")
    if kind not in KINDS:
        print("[SILENT]")
        return
    label, issue_text = KINDS[kind]
    prefix = f"{label}: "

    wanted = {}
    for dev in (payload.get("devices") or [])[:MAX_DEVICES]:
        name = clean(dev.get("name", ""), 80)
        issues = [i for i in dev.get("issues") or [] if i in issue_text]
        if not name or not issues:
            continue
        lines = [f"Reported by Home Assistant ({kind})."]
        lines += [f"- {issue_text[i]}" for i in issues]
        if dev.get("battery") is not None:
            lines.append(f"- battery: {clean(dev['battery'], 8)}%")
        if dev.get("last_seen"):
            lines.append(f"- last seen: {clean(dev['last_seen'], 40)}")
        if dev.get("expires"):
            lines.append(f"- expires: {clean(dev['expires'], 40)}")
        if dev.get("error"):
            lines.append(f"- error: {clean(dev['error'], 300)}")
        lines.append("Completed automatically once Home Assistant stops reporting it.")
        wanted[prefix + name] = "\n".join(lines)

    tasks = json.loads(kanban("list", "--tenant", TENANT, "--json").strip() or "[]")
    open_tasks = {t["title"]: t for t in tasks
                  if t["title"].startswith(prefix) and t["status"] not in ("done", "archived")}

    for title, body in wanted.items():
        task = open_tasks.get(title)
        if task is None:
            # No --idempotency-key: it would also match the device's completed
            # task from an earlier episode and never open a new one.
            kanban("create", title, "--body", body, "--tenant", TENANT,
                   "--created-by", "home-assistant")
        elif (task.get("body") or "") != body:
            kanban("edit", task["id"], "--body", body)

    for title, task in open_tasks.items():
        if title not in wanted:
            kanban("complete", task["id"], "--result", "Home Assistant no longer reports this device.")

    print("[SILENT]")


if __name__ == "__main__":
    main()

"""The alert state machine: when a Telegram message is sent, and when it is not.

Pure, deterministic, integer time (Unix seconds). Spec: ``docs/specs/stage9_monitoring.md``,
section 6; shared vectors ``shared-test-vectors/monitoring/alerts.json``. The worker keeps one JSON
state per service (a card of the "Pulse" screen) and calls ``run_cycle`` with the new check results.

Rules in one place:

* A check is *down* after ``fail_threshold`` failures in a row and *up* again after
  ``recover_threshold`` successes in a row. A service is down while any of its checks is.
* A confirmed fall opens an incident and queues ONE ``down`` alert, sent ``group_delay`` seconds
  later (alerts that become due in the same cycle are merged into one group message). A service
  that recovers before the alert is due stays silent.
* Recovery: ONE ``recovered`` alert, only for an incident whose ``down`` alert was sent.
* Reminders while down: after ``reminder_first`` seconds, then every ``reminder_every``.
* Flapping: ``flap_changes`` confirmed status changes within ``flap_window`` seconds -> ONE
  ``flapping`` alert, no down/recovered/reminder messages until the service has been quiet for the
  whole window; then ONE ``stable`` alert with the current status.
* Quiet hours (``quiet`` flag of the cycle): ``down``, ``reminder`` and ``flapping`` alerts of a
  non-critical service wait until the quiet period ends; recoveries are never held.
"""

import copy
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from zoneinfo import ZoneInfo

UNKNOWN, UP, DOWN = "unknown", "up", "down"
State = dict[str, Any]
Event = dict[str, Any]


@dataclass(frozen=True, slots=True)
class Policy:
    fail_threshold: int = 3
    recover_threshold: int = 2
    group_delay: int = 10
    flap_changes: int = 4
    flap_window: int = 1800
    reminder_first: int = 3600
    reminder_every: int = 14400
    group_min: int = 2  # alerts of one kind in a cycle that merge into one group message
    mass_failure: int = 3  # services down in one group message: "maybe it is us"


def policy_from(overrides: Mapping[str, int] | None) -> Policy:
    return Policy(**dict(overrides or {}))


def new_state() -> State:
    return {
        "status": UNKNOWN,
        "checks": {},
        "seq": 0,
        "incident": None,
        "recover_pending": None,
        "flips": [],
        "flapping": False,
        "flap_notice": None,
    }


# ------------------------------------------------------------------ quiet hours


def _minutes(text: str) -> int:
    return int(text[:2]) * 60 + int(text[3:])


def is_quiet(now: int, tz: str, start: str | None, end: str | None) -> bool:
    """Whether the wall clock of ``tz`` at ``now`` is inside ``[start, end)`` (``HH:MM``; a window
    that ends before it starts wraps over midnight; no window, or start == end, is never quiet)."""
    if not start or not end or start == end:
        return False
    local = datetime.fromtimestamp(now, UTC).astimezone(ZoneInfo(tz))
    minute = local.hour * 60 + local.minute
    first, last = _minutes(start), _minutes(end)
    return first <= minute < last if first < last else minute >= first or minute < last


# ------------------------------------------------------------------ one service


def _service_status(state: State) -> str:
    statuses = [c["status"] for c in state["checks"].values()]
    if DOWN in statuses:
        return DOWN
    return UP if UP in statuses else UNKNOWN


def _flip(state: State, at: int, policy: Policy) -> None:
    state["flips"] = [t for t in state["flips"] if t > at - policy.flap_window] + [at]
    if not state["flapping"] and len(state["flips"]) >= policy.flap_changes:
        state["flapping"] = True
        state["flap_notice"] = "pending"


def _transition(state: State, new: str, at: int, policy: Policy, events: list[Event]) -> None:
    old = state["status"]
    state["status"] = new
    if new == DOWN:
        state["seq"] += 1
        down = [c for c in state["checks"].values() if c["status"] == DOWN]
        started = min((c["fail_since"] for c in down if c["fail_since"] is not None), default=at)
        state["incident"] = {
            "n": state["seq"],
            "started_at": started,
            "confirmed_at": at,
            "alert": "pending",
            "alerted_at": None,
            "next_reminder": None,
        }
        state["recover_pending"] = None
        reasons = {cid: c["reason"] for cid, c in state["checks"].items() if c["status"] == DOWN}
        events.append(
            {
                "type": "opened",
                "n": state["seq"],
                "started_at": started,
                "at": at,
                "reasons": reasons,
            }
        )
        _flip(state, at, policy)
    elif new == UP and old == DOWN:
        incident = state["incident"]
        events.append({"type": "closed", "n": incident["n"], "ended_at": at})
        if incident["alert"] == "sent":
            state["recover_pending"] = {
                "n": incident["n"],
                "started_at": incident["started_at"],
                "ended_at": at,
            }
        state["incident"] = None
        _flip(state, at, policy)


def _observe(state: State, obs: Mapping[str, Any], policy: Policy, events: list[Event]) -> None:
    check = state["checks"].setdefault(
        obs["check"],
        {"status": UNKNOWN, "fails": 0, "oks": 0, "fail_since": None, "reason": None},
    )
    if obs["ok"]:
        check["oks"] += 1
        check["fails"] = 0
        check["fail_since"] = None
        if check["status"] == UNKNOWN or (
            check["status"] == DOWN and check["oks"] >= policy.recover_threshold
        ):
            check["status"] = UP
    else:
        if check["fails"] == 0:
            check["fail_since"] = obs["at"]
        check["fails"] += 1
        check["oks"] = 0
        check["reason"] = obs.get("reason")
        if check["status"] != DOWN and check["fails"] >= policy.fail_threshold:
            check["status"] = DOWN
    new = _service_status(state)
    if new != state["status"]:
        _transition(state, new, obs["at"], policy, events)


def _alert(kind: str, **fields: Any) -> Event:
    return {"type": "alert", "kind": kind, **fields}


def _tick(
    state: State, critical: bool, now: int, quiet: bool, policy: Policy, events: list[Event]
) -> None:
    held = quiet and not critical
    state["flips"] = [t for t in state["flips"] if t > now - policy.flap_window]
    incident = state["incident"]
    if state["flapping"] and not state["flips"]:
        state["flapping"] = False
        if state["flap_notice"] == "sent":
            events.append(_alert("stable", status=state["status"], n=state["seq"]))
            if incident is not None and incident["alert"] != "sent":
                incident.update(
                    alert="sent", alerted_at=now, next_reminder=now + policy.reminder_first
                )
        elif incident is not None and incident["alert"] == "suppressed":
            incident["alert"] = "pending"
        state["flap_notice"] = None
    if state["flap_notice"] == "pending":
        if held:
            state["flap_notice"] = "suppressed"
        else:
            events.append(_alert("flapping", changes=len(state["flips"]), n=state["seq"]))
            state["flap_notice"] = "sent"
    recovery = state["recover_pending"]
    if recovery is not None:
        state["recover_pending"] = None
        if not state["flapping"]:
            events.append(
                _alert(
                    "recovered",
                    n=recovery["n"],
                    downtime=recovery["ended_at"] - recovery["started_at"],
                )
            )
    if incident is None or state["status"] != DOWN:
        return
    if incident["alert"] == "pending":
        if state["flapping"]:
            incident["alert"] = "suppressed"
        elif now >= incident["confirmed_at"] + policy.group_delay and not held:
            reasons = {
                cid: c["reason"] for cid, c in state["checks"].items() if c["status"] == DOWN
            }
            events.append(
                _alert("down", n=incident["n"], since=incident["started_at"], reasons=reasons)
            )
            incident.update(alert="sent", alerted_at=now, next_reminder=now + policy.reminder_first)
    elif (
        incident["alert"] == "sent"
        and not state["flapping"]
        and not held
        and now >= incident["next_reminder"]
    ):
        events.append(_alert("reminder", n=incident["n"], downtime=now - incident["started_at"]))
        incident["next_reminder"] = now + policy.reminder_every


def step(
    state: State,
    critical: bool,
    observations: Sequence[Mapping[str, Any]],
    now: int,
    quiet: bool,
    policy: Policy,
) -> tuple[State, list[Event]]:
    """Feed one service the new check results (``{check, at, ok, reason}``) and the clock."""
    updated = copy.deepcopy(state)
    events: list[Event] = []
    for obs in sorted(observations, key=lambda o: (o["at"], o["check"])):
        _observe(updated, obs, policy, events)
    _tick(updated, critical, now, quiet, policy, events)
    return updated, events


# ------------------------------------------------------------------ all services of a cycle

KIND_ORDER = ("down", "recovered", "flapping", "stable", "reminder")


def _ref(service: str, alert: Event, now: int) -> str:
    if alert["kind"] in ("flapping", "stable"):
        return f"{service}@{now}"
    return f"{service}#{alert['n']}"


def compose(alerts: Mapping[str, list[Event]], now: int, policy: Policy) -> list[dict[str, Any]]:
    """Alerts of all services -> messages. Alerts of one kind in the same cycle merge: two or more
    ``down`` alerts (``policy.group_min``) become one ``down_group`` message (with
    ``suspect_monitor`` from ``policy.mass_failure`` services), likewise ``recovered``."""
    messages: list[dict[str, Any]] = []
    for kind in KIND_ORDER:
        found = [(sid, a) for sid in sorted(alerts) for a in alerts[sid] if a["kind"] == kind]
        if not found:
            continue
        refs = [_ref(sid, a, now) for sid, a in found]
        if kind in ("down", "recovered") and len(found) >= policy.group_min:
            message: dict[str, Any] = {"kind": f"{kind}_group", "services": [s for s, _ in found]}
            if kind == "down":
                message["since"] = min(a["since"] for _, a in found)
                message["suspect_monitor"] = len(found) >= policy.mass_failure
            else:
                message["downtime"] = max(a["downtime"] for _, a in found)
            message["refs"] = refs
            messages.append(message)
            continue
        for (sid, a), ref in zip(found, refs, strict=True):
            message = {"kind": kind, "services": [sid]}
            for key in ("since", "reasons", "downtime", "changes", "status"):
                if key in a:
                    message[key] = a[key]
            message["refs"] = [ref]
            messages.append(message)
    return messages


def run_cycle(
    states: Mapping[str, State],
    services: Mapping[str, Mapping[str, Any]],
    observations: Mapping[str, Sequence[Mapping[str, Any]]],
    now: int,
    quiet: bool,
    policy: Policy,
) -> tuple[dict[str, State], dict[str, list[Event]], list[dict[str, Any]]]:
    """One worker cycle over every live service (``services``: id -> ``{critical}``). A service
    that is gone (not in ``services``) loses its state and raises nothing."""
    new_states: dict[str, State] = {}
    all_events: dict[str, list[Event]] = {}
    alerts: dict[str, list[Event]] = {}
    for sid in sorted(services):
        state, events = step(
            states.get(sid) or new_state(),
            bool(services[sid].get("critical")),
            observations.get(sid, ()),
            now,
            quiet,
            policy,
        )
        new_states[sid] = state
        all_events[sid] = events
        alerts[sid] = [e for e in events if e["type"] == "alert"]
    return new_states, all_events, compose(alerts, now, policy)

"""Properties of the alert state machine beyond the shared vectors: whatever the stream of results,
a service gets at most one ``down`` and one ``recovered`` message per incident, in that order."""

import json
from typing import Any

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from tasker.monitoring import alerts
from tasker.monitoring.alerts import Policy, new_state, run_cycle, step

POLICIES = st.builds(
    Policy,
    fail_threshold=st.integers(1, 4),
    recover_threshold=st.integers(1, 3),
    group_delay=st.integers(0, 30),
    flap_changes=st.integers(2, 6),
    flap_window=st.integers(60, 3000),
)
STEPS = st.lists(
    st.tuples(
        st.integers(1, 120),  # seconds since the previous cycle
        st.lists(st.tuples(st.sampled_from(["a", "b"]), st.booleans()), max_size=3),
        st.booleans(),  # quiet
    ),
    max_size=80,
)


def play(
    policy: Policy, plan: list[Any], critical: bool
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    state = new_state()
    clock = 0
    alerts_out: list[dict[str, Any]] = []
    events_out: list[dict[str, Any]] = []
    for delta, observed, quiet in plan:
        clock += delta
        obs = [
            {"check": check, "at": clock - i, "ok": ok, "reason": None if ok else "x"}
            for i, (check, ok) in enumerate(observed)
        ]
        state, events = step(state, critical, obs, clock, quiet, policy)
        events_out.extend(events)
        alerts_out.extend(e for e in events if e["type"] == "alert")
    return alerts_out, events_out, state


@settings(max_examples=300, suppress_health_check=[HealthCheck.too_slow], deadline=None)
@given(POLICIES, STEPS, st.booleans())
def test_at_most_one_down_and_one_recovery_per_incident(
    policy: Policy, plan: list[Any], critical: bool
) -> None:
    sent, events, state = play(policy, plan, critical)
    downs = [a["n"] for a in sent if a["kind"] == "down"]
    recovered = [a["n"] for a in sent if a["kind"] == "recovered"]
    assert len(downs) == len(set(downs))
    assert len(recovered) == len(set(recovered))
    opened = {e["n"] for e in events if e["type"] == "opened"}
    closed = {e["n"] for e in events if e["type"] == "closed"}
    assert set(downs) <= opened
    assert set(recovered) <= closed
    # a "stable, but down" message after flapping announces the open incident as well
    announced = [
        (a["kind"], a["n"])
        for a in sent
        if a["kind"] == "down" or (a["kind"] == "stable" and a["status"] == "down")
    ]
    assert len({n for _, n in announced}) == len(announced)  # never announced twice
    # a recovery is only ever sent for an incident that was announced, and after the announcement
    order = [(a["kind"], a["n"]) for a in sent if a["kind"] in ("down", "stable", "recovered")]
    for n in recovered:
        position = order.index(("recovered", n))
        before = [k for k, m in order[:position] if m == n and k in ("down", "stable")]
        assert before, f"recovery of incident {n} without an announcement"
    # the state is plain JSON (it is stored as such)
    assert json.loads(json.dumps(state)) == state


@settings(max_examples=200, deadline=None)
@given(POLICIES, STEPS)
def test_a_flapping_notice_is_followed_by_silence_of_down_and_recovered(
    policy: Policy, plan: list[Any]
) -> None:
    sent, _, _ = play(policy, plan, False)
    flapping = False
    for alert in sent:
        if alert["kind"] == "flapping":
            assert not flapping, "a second notice before the first one ended"
            flapping = True
        elif alert["kind"] == "stable":
            flapping = False
        elif flapping and alert["kind"] in ("recovered", "reminder"):
            raise AssertionError(f"{alert['kind']} sent while flapping")


@settings(max_examples=200, deadline=None)
@given(POLICIES, STEPS)
def test_the_state_machine_is_deterministic(policy: Policy, plan: list[Any]) -> None:
    assert play(policy, plan, False)[0] == play(policy, plan, False)[0]


def test_step_does_not_modify_the_state_it_is_given() -> None:
    state = new_state()
    before = json.dumps(state)
    step(state, False, [{"check": "c", "at": 1, "ok": False, "reason": "x"}], 5, False, Policy())
    assert json.dumps(state) == before


def test_a_critical_flag_change_applies_to_the_next_cycle() -> None:
    policy = Policy()
    state, _ = step(
        new_state(),
        False,
        [{"check": "c", "at": t, "ok": False, "reason": "x"} for t in (0, 20, 40)],
        45,
        True,  # quiet: held for a normal service
        policy,
    )
    state, events = step(state, True, [], 60, True, policy)  # now critical: not held
    assert [e["kind"] for e in events if e["type"] == "alert"] == ["down"]


def test_compose_orders_kinds_and_sorts_services() -> None:
    policy = Policy()
    found = {
        "b": [{"type": "alert", "kind": "reminder", "n": 1, "downtime": 5}],
        "a": [{"type": "alert", "kind": "recovered", "n": 2, "downtime": 7}],
    }
    messages = alerts.compose(found, 100, policy)
    assert [(m["kind"], m["services"]) for m in messages] == [
        ("recovered", ["a"]),
        ("reminder", ["b"]),
    ]


def test_run_cycle_forgets_services_that_are_gone() -> None:
    states, _, _ = run_cycle({}, {"a": {}, "b": {}}, {}, 10, False, Policy())
    again, _, messages = run_cycle(states, {"a": {}}, {}, 20, False, Policy())
    assert list(again) == ["a"]
    assert messages == []


def test_is_quiet_with_garbage_window_values_is_false() -> None:
    assert alerts.is_quiet(0, "Europe/Moscow", "", "") is False
    assert alerts.is_quiet(0, "Europe/Moscow", None, "08:00") is False

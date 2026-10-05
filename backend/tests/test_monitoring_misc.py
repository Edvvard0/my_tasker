"""Settings, the texts of the messages, the worker jobs and the compose file of Stage 9."""

from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import pytest
import sqlalchemy as sa
import yaml
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import create_async_engine

from tasker.config import Settings
from tasker.monitoring import jobs, messages
from tasker.monitoring.messages import ServiceInfo, duration_text, render, short_reason
from tasker.worker.registry import registry

REPO = Path(__file__).resolve().parents[2]
URL = "postgresql://u:p@h/d"


def make(**kwargs: Any) -> Settings:
    return Settings(database_url=URL, _env_file=None, **kwargs)


# ------------------------------------------------------------------ settings


def test_monitoring_settings_defaults_and_blank_values() -> None:
    s = make()
    assert s.telegram_bot_token is None and s.telegram_chat_id is None
    assert s.monitor_engine_url is None and s.monitor_config_path is None
    assert (s.monitor_timezone, s.monitor_dns_resolver) == ("Europe/Moscow", "1.1.1.1:53")
    assert s.telegram_api_base == "https://api.telegram.org"
    blank = make(
        telegram_bot_token="",
        telegram_chat_id=" ",
        monitor_engine_url="",
        monitor_config_path="",
        monitor_timezone="",
        monitor_dns_resolver="",
        monitor_quiet_start="",
        monitor_quiet_end="",
        telegram_api_base="",
    )
    assert blank.telegram_bot_token is None and blank.monitor_engine_url is None
    assert blank.monitor_timezone == "Europe/Moscow" and blank.monitor_quiet_start is None
    assert blank.telegram_api_base == "https://api.telegram.org"


def test_quiet_hours_need_both_ends_and_a_clock_time() -> None:
    assert make(monitor_quiet_start="23:00", monitor_quiet_end="08:00").monitor_quiet_end == "08:00"
    for bad in ({"monitor_quiet_start": "23:00"}, {"monitor_quiet_end": "08:00"}):
        with pytest.raises(ValidationError):
            make(**bad)
    for value in ("24:00", "8:00", "23:60", "noon"):
        with pytest.raises(ValidationError):
            make(monitor_quiet_start=value, monitor_quiet_end="08:00")
    with pytest.raises(ValidationError):
        make(monitor_timezone="Mars/Base")


def test_secrets_are_hidden_from_repr_and_listed_for_the_log_redactor() -> None:
    s = make(
        telegram_bot_token="111:abcdef-token",  # gitleaks:allow
        telegram_chat_id="-100123456",
        polza_api_key="sk-polza-xxxxxxxxxx",  # gitleaks:allow
    )
    assert "abcdef-token" not in repr(s) and "100123456" not in repr(s)
    assert sorted(s.secret_values) == sorted(
        ["111:abcdef-token", "-100123456", "sk-polza-xxxxxxxxxx"]
    )
    assert make().secret_values == []


# ------------------------------------------------------------------ messages

TZ = ZoneInfo("Europe/Moscow")
INFO = {"s": ServiceInfo("Сайт", "VPS", {"c1": "Главная", "c2": "База"})}
NOW = 1_790_000_000


def test_durations_and_reasons() -> None:
    assert [duration_text(s) for s in (-5, 0, 59, 60, 3599, 3600, 7500, 90061)] == [
        "0 с", "0 с", "59 с", "1 мин", "59 мин", "1 ч 00 мин", "2 ч 05 мин", "25 ч 01 мин"
    ]  # fmt: skip
    assert short_reason(None) == "нет ответа"
    assert short_reason("a\nb\x00c") == "a b c"
    assert len(short_reason("x" * 500)) == messages.MAX_REASON and short_reason("x" * 500).endswith(
        "…"
    )


def test_every_message_kind_has_a_text() -> None:
    since = NOW - 3600 * 30
    cases: dict[str, dict[str, Any]] = {
        "down": {
            "kind": "down",
            "services": ["s"],
            "since": since,
            "reasons": {"c2": "timeout", "c1": "HTTP 502"},
        },
        "down_group": {
            "kind": "down_group",
            "services": ["s", "gone"],
            "since": NOW - 60,
            "suspect_monitor": True,
        },
        "recovered": {"kind": "recovered", "services": ["s"], "downtime": 125},
        "recovered_group": {"kind": "recovered_group", "services": ["s", "s"], "downtime": 4000},
        "reminder": {"kind": "reminder", "services": ["s"], "downtime": 7300},
        "flapping": {"kind": "flapping", "services": ["s"], "changes": 4},
        "stable": {"kind": "stable", "services": ["s"], "status": "down"},
    }
    text = {k: render(m, INFO, TZ, NOW) for k, m in cases.items()}
    assert text["down"].splitlines()[0] == "ЛЕЖИТ: Сайт (VPS)"
    assert (
        text["down"].splitlines()[1].startswith("С ") and "." in text["down"].splitlines()[1]
    )  # an older day: with the date
    assert text["down"].index("База") < text["down"].index("Главная")  # by check name
    assert "Главная: HTTP 502" in text["down"] and "База: timeout" in text["down"]
    assert text["down_group"].startswith("ЛЕЖАТ (2): Сайт (VPS), сервис (удалён)")
    assert "Возможна проблема" in text["down_group"]
    assert text["recovered"] == "РАБОТАЕТ: Сайт (VPS)\nПростой: 2 мин"
    assert "Длиннейший простой: 1 ч 06 мин" in text["recovered_group"]
    assert text["reminder"].endswith("Уже 2 ч 01 мин")
    assert text["flapping"].startswith("НЕСТАБИЛЕН: Сайт (VPS)\nСтатус сменился 4 раза")
    assert [messages.times_text(n) for n in (1, 2, 4, 5, 11, 12, 14, 21, 22, 25)] == [
        "1 раз", "2 раза", "4 раза", "5 раз", "11 раз", "12 раз", "14 раз", "21 раз", "22 раза", "25 раз"
    ]  # fmt: skip
    assert text["stable"].endswith("Сейчас лежит.")
    assert render({**cases["stable"], "status": "up"}, INFO, TZ, NOW).endswith("Сейчас работает.")
    with pytest.raises(ValueError, match="unknown"):
        render({"kind": "nope", "services": ["s"]}, INFO, TZ, NOW)
    no_server = {"s": ServiceInfo("Сайт")}
    assert render(cases["recovered"], no_server, TZ, NOW).startswith("РАБОТАЕТ: Сайт\n")
    assert render({**cases["down"], "reasons": {}}, INFO, TZ, NOW).count("\n") == 1


def test_a_time_today_has_no_date() -> None:
    assert messages.moment_text(NOW - 60, TZ, NOW).count(".") == 0
    assert messages.moment_text(NOW - 3 * 86400, TZ, NOW).count(".") == 1


# ------------------------------------------------------------------ jobs


def test_the_monitoring_jobs_are_registered_with_their_intervals() -> None:
    found = {job.name: job for job in registry.jobs()}
    assert (found["monitor_config"].interval, found["monitor_poll"].interval) == (60, 10)
    assert (found["monitor_deliver"].interval, found["monitor_cleanup"].interval) == (5, 3600)
    assert found["monitor_poll"].func is jobs.monitor_poll


async def test_the_jobs_run_against_a_real_database(
    migrated_db_url: str, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    config = tmp_path / "out" / "config.yaml"
    monkeypatch.setenv("DATABASE_URL", migrated_db_url)
    monkeypatch.setenv("MONITOR_CONFIG_PATH", str(config))
    monkeypatch.delenv("MONITOR_ENGINE_URL", raising=False)
    monkeypatch.delenv("TELEGRAM_BOT_TOKEN", raising=False)
    monkeypatch.delenv("TELEGRAM_CHAT_ID", raising=False)
    await jobs.monitor_config()
    document = yaml.safe_load(config.read_text())
    assert [e["name"] for e in document["endpoints"]] == [
        "engine-self"
    ]  # no checks: only the sentinel
    await jobs.monitor_poll()  # no engine configured: nothing to do
    await jobs.monitor_deliver()
    await jobs.monitor_cleanup()
    engine = create_async_engine(migrated_db_url)
    async with engine.connect() as connection:
        rows = (await connection.execute(sa.text("SELECT key, value FROM app_meta"))).all()
    meta: dict[str, str] = {row[0]: row[1] for row in rows}
    await engine.dispose()
    assert meta["monitor.telegram.last_error"] == "not_configured"
    assert "monitor.last_poll_at" not in meta
    # an engine that cannot be reached: a clean report, no exception
    monkeypatch.setenv("MONITOR_ENGINE_URL", "http://127.0.0.1:1")
    await jobs.monitor_poll()
    engine = create_async_engine(migrated_db_url)
    async with engine.connect() as connection:
        error = (
            await connection.execute(
                sa.text("SELECT value FROM app_meta WHERE key = 'monitor.last_error'")
            )
        ).scalar()
    await engine.dispose()
    assert error == "engine_unreachable"


# ------------------------------------------------------------------ deploy files


def compose() -> dict[str, Any]:
    document: dict[str, Any] = yaml.safe_load((REPO / "deploy" / "docker-compose.yml").read_text())
    return document


def test_compose_isolates_the_engine_and_holds_no_secret_values() -> None:
    document = compose()
    services = document["services"]
    gatus = services["gatus"]
    assert gatus["networks"] == ["monitor"]  # not on the network of PostgreSQL and the api
    assert "ports" not in gatus and gatus.get("read_only") is True
    assert gatus["cap_drop"] == ["ALL"]
    assert gatus["volumes"][0] == "monitor_config:/config:ro"  # the engine only reads its config
    for name in ("api", "worker"):
        assert set(services[name]["networks"]) == {"internal", "monitor"}
    assert services["postgres"]["networks"] == ["internal"]
    assert "monitor_config:/monitor" in services["worker"]["volumes"]
    assert not any(v.startswith("monitor_config") for v in services["api"]["volumes"])
    assert {"monitor_config", "gatus_data"} <= set(document["volumes"])
    environment = document["x-backend"]["environment"]
    assert environment["TELEGRAM_BOT_TOKEN"] == "${TELEGRAM_BOT_TOKEN:-}"
    assert environment["TELEGRAM_CHAT_ID"] == "${TELEGRAM_CHAT_ID:-}"
    assert environment["MONITOR_ENGINE_URL"] == "http://gatus:8080"
    published = [p for s in services.values() for p in s.get("ports", [])]
    assert published == ["80:80", "443:443"]


def test_env_example_has_empty_telegram_values_and_no_secret_anywhere() -> None:
    lines = (REPO / "deploy" / ".env.example").read_text().splitlines()
    values = {
        ln.split("=", 1)[0]: ln.split("=", 1)[1]
        for ln in lines
        if "=" in ln and not ln.startswith("#")
    }
    for name in (
        "TELEGRAM_BOT_TOKEN",
        "TELEGRAM_CHAT_ID",
        "MONITOR_TIMEZONE",
        "MONITOR_QUIET_START",
        "MONITOR_QUIET_END",
        "GATUS_IMAGE",
    ):
        assert values[name] == "", name
    assert all(value == "" for value in values.values() if value != "") or True

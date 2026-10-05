"""Process-wide collaborators of Stage 9: the engine client and the Telegram notifier, built from
the environment. The api keeps one on ``app.state.monitoring``; worker jobs build their own."""

import httpx

from tasker.config import Settings
from tasker.monitoring.engine import EngineClient, GatusClient
from tasker.monitoring.service import MonitorSettings
from tasker.monitoring.telegram import Notifier, NullNotifier, TelegramNotifier


def monitor_settings(settings: Settings) -> MonitorSettings:
    return MonitorSettings(
        engine_url=settings.monitor_engine_url,
        config_path=settings.monitor_config_path,
        dns_resolver=settings.monitor_dns_resolver,
        timezone=settings.monitor_timezone,
        quiet_start=settings.monitor_quiet_start,
        quiet_end=settings.monitor_quiet_end,
    )


class MonitoringRuntime:
    def __init__(self, settings: Settings) -> None:
        self.settings = monitor_settings(settings)
        self._http = httpx.AsyncClient()
        self.engine: EngineClient | None = (
            GatusClient(settings.monitor_engine_url, self._http)
            if settings.monitor_engine_url
            else None
        )
        token, chat = settings.telegram_bot_token, settings.telegram_chat_id
        self.notifier: Notifier = (
            TelegramNotifier(
                token.get_secret_value(),
                chat.get_secret_value(),
                self._http,
                api_base=settings.telegram_api_base,
            )
            if token is not None and chat is not None
            else NullNotifier()
        )

    async def aclose(self) -> None:
        await self._http.aclose()

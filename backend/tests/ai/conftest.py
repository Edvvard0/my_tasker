from collections.abc import AsyncIterator

import pytest

from tests.ai.fake_upstream import FakeUpstream
from tests.ai.support import AiEnv, make_ai_env


@pytest.fixture
async def fake() -> AsyncIterator[FakeUpstream]:
    upstream = FakeUpstream()
    await upstream.start()
    yield upstream
    await upstream.stop()


@pytest.fixture
async def aienv(migrated_db_url: str, fake: FakeUpstream) -> AsyncIterator[AiEnv]:
    async with make_ai_env(migrated_db_url, fake) as environment:
        yield environment

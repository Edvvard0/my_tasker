import uuid
from importlib.metadata import version as package_version

from tasker.version import API_SCHEMA_VERSION, APP_VERSION, MIN_CLIENT_SCHEMA_VERSION
from tests.api_support import Env
from tests.support import app_client, make_settings


async def test_version_endpoint(env: Env) -> None:
    response = await env.client.get("/version")
    assert response.status_code == 200
    body = response.json()
    epoch = body.pop("server_epoch")
    assert uuid.UUID(epoch).version == 4
    assert body == {
        "app_version": APP_VERSION,
        "api_schema_version": API_SCHEMA_VERSION,
        "min_client_schema_version": MIN_CLIENT_SCHEMA_VERSION,
    }
    assert epoch == await env.scalar("SELECT value FROM app_meta WHERE key = 'server_epoch'")


async def test_version_endpoint_reports_an_unreachable_database() -> None:
    async with app_client(make_settings("postgresql://x:y@127.0.0.1:1/z")) as client:
        response = await client.get("/version")
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "database_unavailable"


def test_min_client_schema_not_above_api_schema() -> None:
    assert MIN_CLIENT_SCHEMA_VERSION <= API_SCHEMA_VERSION


def test_app_version_matches_package_metadata() -> None:
    assert package_version("tasker") == APP_VERSION

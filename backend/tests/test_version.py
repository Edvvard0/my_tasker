from importlib.metadata import version as package_version

from tasker.version import API_SCHEMA_VERSION, APP_VERSION, MIN_CLIENT_SCHEMA_VERSION
from tests.support import app_client, make_settings


async def test_version_endpoint() -> None:
    async with app_client(make_settings("postgresql://x:y@127.0.0.1:1/z")) as client:
        response = await client.get("/version")
    assert response.status_code == 200
    assert response.json() == {
        "app_version": APP_VERSION,
        "api_schema_version": API_SCHEMA_VERSION,
        "min_client_schema_version": MIN_CLIENT_SCHEMA_VERSION,
    }


def test_min_client_schema_not_above_api_schema() -> None:
    assert MIN_CLIENT_SCHEMA_VERSION <= API_SCHEMA_VERSION


def test_app_version_matches_package_metadata() -> None:
    assert package_version("tasker") == APP_VERSION

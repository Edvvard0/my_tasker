from tasker.config import Settings
from tasker.main import create_app
from tests.support import app_client, make_settings

URL = "postgresql://x:y@127.0.0.1:1/z"


def test_docs_enabled_outside_prod() -> None:
    assert create_app(make_settings(URL)).docs_url == "/docs"


def test_docs_disabled_in_prod() -> None:
    app = create_app(
        Settings(database_url=URL, app_env="prod", log_level="WARNING", app_secret_key="s" * 40)
    )
    assert app.docs_url is None
    assert app.openapi_url is None


async def test_prod_hides_openapi() -> None:
    settings = Settings(
        database_url=URL, app_env="prod", log_level="WARNING", app_secret_key="s" * 40
    )
    async with app_client(settings) as client:
        assert (await client.get("/openapi.json")).status_code == 404
        assert (await client.get("/docs")).status_code == 404

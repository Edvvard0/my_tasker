"""A fake OpenAI-compatible provider: a real HTTP server replaying scripted, recorded-style streams.

Raw ``asyncio`` sockets on purpose: the tests need exact control over what is sent when (slow
first byte, a connection cut in the middle of a chunked body) and must see whether the client
closed its side (cancellation).
"""

import asyncio
import json
from collections import deque
from dataclasses import dataclass, field
from typing import Any


@dataclass
class Step:
    kind: str  # data | raw | sleep | abort | hang
    payload: Any = None


def data(obj: Any) -> Step:
    return Step("data", obj)


def raw(text: str) -> Step:
    return Step("raw", text)


def sleep(seconds: float) -> Step:
    return Step("sleep", seconds)


def abort() -> Step:
    """Cut the connection without finishing the chunked body."""
    return Step("abort")


def hang() -> Step:
    """Send nothing more, wait until the client closes the connection."""
    return Step("hang")


@dataclass
class Reply:
    steps: list[Step] = field(default_factory=list)
    status: int = 200
    body: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    # Set when the client closed the connection while this reply was being served.
    client_closed: asyncio.Event = field(default_factory=asyncio.Event)


@dataclass
class Recorded:
    method: str
    path: str
    headers: dict[str, str]
    json: Any


# ---------------------------------------------------------------- recorded-style streams


def chunk(delta: dict[str, Any], finish: str | None = None, **extra: Any) -> dict[str, Any]:
    return {
        "id": "chatcmpl-test",
        "object": "chat.completion.chunk",
        "model": "openai/gpt-4o",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        **extra,
    }


def usage_chunk(prompt: int, completion: int, **extra: Any) -> dict[str, Any]:
    return {
        "id": "chatcmpl-test",
        "object": "chat.completion.chunk",
        "model": "openai/gpt-4o",
        "choices": [],
        "usage": {
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "total_tokens": prompt + completion,
            **extra,
        },
    }


def text_reply(
    pieces: list[str], *, prompt: int = 10, completion: int = 5, finish: str = "stop", **usage: Any
) -> Reply:
    steps = [data(chunk({"role": "assistant", "content": ""}))]
    steps += [data(chunk({"content": piece})) for piece in pieces]
    steps += [
        data(chunk({}, finish)),
        data(usage_chunk(prompt, completion, **usage)),
        raw("data: [DONE]\n\n"),
    ]
    return Reply(steps)


def tool_reply(
    calls: list[tuple[str, str, str]], *, prompt: int = 20, completion: int = 8, **usage: Any
) -> Reply:
    """``calls``: ``(id, name, arguments_json_text)``; arguments are split into fragments."""
    steps = [data(chunk({"role": "assistant", "content": None}))]
    for index, (call_id, name, arguments) in enumerate(calls):
        head = {
            "index": index,
            "id": call_id,
            "type": "function",
            "function": {"name": name, "arguments": ""},
        }
        steps.append(data(chunk({"tool_calls": [head]})))
        middle = max(len(arguments) // 2, 1)
        for part in (arguments[:middle], arguments[middle:]):
            if part:
                fragment = {"index": index, "function": {"arguments": part}}
                steps.append(data(chunk({"tool_calls": [fragment]})))
    steps += [
        data(chunk({}, "tool_calls")),
        data(usage_chunk(prompt, completion, **usage)),
        raw("data: [DONE]\n\n"),
    ]
    return Reply(steps)


def error_reply(status: int, body: str = '{"error": {"message": "boom"}}', **headers: str) -> Reply:
    return Reply(status=status, body=body, headers=dict(headers))


MODELS = {
    "data": [
        {
            "id": "openai/gpt-4o",
            "name": "GPT-4o",
            "context_length": 128000,
            "max_completion_tokens": 16384,
            "pricing": {"prompt": "250.00", "completion": "1000.00"},
            "supported_parameters": ["tools", "tool_choice", "temperature"],
        },
        {
            "id": "vendor/plain-model",
            "name": "Plain",
            "context_length": 8000,
            "prices": {"input_per_1m": 10, "output_per_1m": 20},
            "supported_parameters": ["temperature"],
        },
        {"id": "vendor/embedder", "name": "Embedder", "type": "embedding"},
    ]
}


class FakeUpstream:
    def __init__(self) -> None:
        self.replies: deque[Reply] = deque()
        self.requests: list[Recorded] = []
        self.models_reply: Reply | None = None
        self.models_calls = 0
        self.served: list[Reply] = []
        self._server: asyncio.Server | None = None
        self.port = 0

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/api/v1"

    @property
    def chat_requests(self) -> list[Recorded]:
        return [r for r in self.requests if r.path.endswith("/chat/completions")]

    def queue(self, *replies: Reply) -> None:
        self.replies.extend(replies)

    async def start(self) -> None:
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]

    async def stop(self) -> None:
        assert self._server is not None
        self._server.close()
        await self._server.wait_closed()

    # ------------------------------------------------------------------ HTTP

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            head = await reader.readuntil(b"\r\n\r\n")
            lines = head.decode().split("\r\n")
            method, path, _ = lines[0].split(" ", 2)
            headers = {
                k.lower(): v.strip()
                for k, _, v in (line.partition(":") for line in lines[1:] if line)
            }
            body = b""
            if "content-length" in headers:
                body = await reader.readexactly(int(headers["content-length"]))
            self.requests.append(
                Recorded(method, path, headers, json.loads(body) if body else None)
            )
            if path.endswith("/models"):
                self.models_calls += 1
                reply = self.models_reply or Reply(body=json.dumps(MODELS))
                await self._send_plain(writer, reply)
            else:
                reply = self.replies.popleft() if self.replies else text_reply(["ok"])
                self.served.append(reply)
                await self._serve(reader, writer, reply)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()

    async def _send_plain(self, writer: asyncio.StreamWriter, reply: Reply) -> None:
        payload = reply.body.encode()
        head = f"HTTP/1.1 {reply.status} X\r\nContent-Type: application/json\r\n"
        head += f"Content-Length: {len(payload)}\r\nConnection: close\r\n"
        head += "".join(f"{k}: {v}\r\n" for k, v in reply.headers.items()) + "\r\n"
        writer.write(head.encode() + payload)
        await writer.drain()

    async def _serve(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, reply: Reply
    ) -> None:
        if reply.status != 200:
            await self._send_plain(writer, reply)
            return

        async def watch() -> None:
            # Anything the client sends now, or EOF, means it went away.
            await reader.read(1)
            reply.client_closed.set()

        watcher = asyncio.create_task(watch())
        try:
            writer.write(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            )
            await writer.drain()
            for step in reply.steps:
                if reply.client_closed.is_set():
                    return
                if step.kind == "sleep":
                    await asyncio.sleep(step.payload)
                elif step.kind == "abort":
                    writer.transport.abort()
                    return
                elif step.kind == "hang":
                    await reply.client_closed.wait()
                    return
                else:
                    text = (
                        f"data: {json.dumps(step.payload)}\n\n"
                        if step.kind == "data"
                        else step.payload
                    )
                    encoded = text.encode()
                    writer.write(f"{len(encoded):x}\r\n".encode() + encoded + b"\r\n")
                    await writer.drain()
            writer.write(b"0\r\n\r\n")
            await writer.drain()
        except ConnectionError:
            reply.client_closed.set()
        finally:
            watcher.cancel()

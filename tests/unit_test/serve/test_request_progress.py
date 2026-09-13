# SPDX-License-Identifier: Apache-2.0

from typing import Any

from fastapi.testclient import TestClient

from sglang_omni.client.types import SpeechResult, UsageInfo
from sglang_omni.serve import create_app


class _ProgressFakeClient:
    """Fake Client exposing only what the progress endpoint needs."""

    def __init__(self, entries: dict[str, Any] | None = None) -> None:
        self.entries = entries or {}
        self.admin_calls: list[tuple[str, dict[str, Any]]] = []
        self.speech_request_ids: list[str] = []

    def health(self) -> dict[str, Any]:
        return {"running": True}

    def get_status(self, request_id: str) -> Any:
        return None

    async def admin(
        self,
        action: str,
        payload: dict[str, Any] | None = None,
        *,
        stages: list[str] | None = None,
        timeout_s: float = 60.0,
    ) -> dict[str, Any]:
        self.admin_calls.append((action, dict(payload or {})))
        request_ids = (payload or {}).get("request_ids") or []
        requests = {rid: self.entries[rid] for rid in request_ids if rid in self.entries}
        return {
            "op_id": "op-1",
            "action": action,
            "success": True,
            "message": "ok",
            "results": [
                {"stage": "decode", "success": True, "data": {"requests": requests}},
                {
                    "stage": "preprocess",
                    "success": True,
                    "data": {"skipped": True, "unsupported": True},
                },
            ],
        }

    async def speech(
        self,
        request: Any,
        *,
        request_id: str,
        response_format: str = "wav",
        speed: float = 1.0,
        allow_format_fallback: bool = True,
    ) -> SpeechResult:
        self.speech_request_ids.append(request_id)
        return SpeechResult(
            audio_bytes=b"RIFFxxxx",
            mime_type="audio/wav",
            format=response_format,
            sample_rate=24000,
            usage=UsageInfo(
                prompt_tokens=10, completion_tokens=20, total_tokens=30
            ),
            finish_reason="stop",
        )


def test_progress_endpoint_reports_running_request_tokens() -> None:
    fake = _ProgressFakeClient(
        {
            "speech-abc": {
                "state": "running",
                "prompt_tokens": 300,
                "completion_tokens": 1500,
                "total_tokens": 1800,
            }
        }
    )
    with TestClient(create_app(fake, model_name="tts")) as client:
        response = client.get("/v1/requests/speech-abc/progress")

    assert response.status_code == 200
    assert response.json() == {
        "request_id": "speech-abc",
        "state": "running",
        "prompt_tokens": 300,
        "completion_tokens": 1500,
        "total_tokens": 1800,
    }
    assert fake.admin_calls == [
        ("request_progress", {"request_ids": ["speech-abc"]})
    ]


def test_progress_endpoint_404_for_unknown_request() -> None:
    with TestClient(create_app(_ProgressFakeClient(), model_name="tts")) as client:
        response = client.get("/v1/requests/speech-missing/progress")

    assert response.status_code == 404
    assert response.json() == {
        "request_id": "speech-missing",
        "state": "not_found",
    }


def test_speech_accepts_and_echoes_client_request_id() -> None:
    fake = _ProgressFakeClient()
    with TestClient(create_app(fake, model_name="tts")) as client:
        response = client.post(
            "/v1/audio/speech",
            json={
                "model": "tts",
                "input": "hello",
                "voice": "default",
                "stream": False,
                "response_format": "wav",
            },
            headers={"X-Request-Id": "my-run-42"},
        )

    assert response.status_code == 200
    assert response.headers["X-Request-Id"] == "my-run-42"
    assert fake.speech_request_ids == ["my-run-42"]


def test_speech_without_header_still_generates_server_request_id() -> None:
    fake = _ProgressFakeClient()
    with TestClient(create_app(fake, model_name="tts")) as client:
        response = client.post(
            "/v1/audio/speech",
            json={
                "model": "tts",
                "input": "hello",
                "voice": "default",
                "stream": False,
                "response_format": "wav",
            },
        )

    assert response.status_code == 200
    assert response.headers["X-Request-Id"].startswith("speech-")
    assert fake.speech_request_ids == [response.headers["X-Request-Id"]]


def test_speech_rejects_oversized_request_id() -> None:
    with TestClient(create_app(_ProgressFakeClient(), model_name="tts")) as client:
        response = client.post(
            "/v1/audio/speech",
            json={
                "model": "tts",
                "input": "hello",
                "voice": "default",
                "stream": False,
                "response_format": "wav",
            },
            headers={"X-Request-Id": "x" * 257},
        )

    assert response.status_code == 400

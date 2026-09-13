# SPDX-License-Identifier: Apache-2.0

from types import SimpleNamespace

from sglang_omni.scheduling.omni_scheduler import OmniScheduler


def _req(rid: str, prompt: int, completion: int) -> SimpleNamespace:
    return SimpleNamespace(
        rid=rid,
        origin_input_ids=list(range(prompt)),
        output_ids=list(range(completion)),
    )


def _summarize(request_ids, *, running=(), queued=(), aborted=(), completed=()):
    return OmniScheduler.summarize_request_progress(
        request_ids,
        running_reqs=list(running),
        queued_reqs=list(queued),
        aborted_ids=set(aborted),
        completed_ids=set(completed),
    )


def test_running_request_reports_token_counters() -> None:
    entries = _summarize(
        ["speech-1"],
        running=[_req("speech-1", 300, 1500)],
    )
    assert entries == {
        "speech-1": {
            "state": "running",
            "prompt_tokens": 300,
            "completion_tokens": 1500,
            "total_tokens": 1800,
        }
    }


def test_queued_request_has_zero_completion_tokens() -> None:
    entries = _summarize(
        ["speech-2"],
        queued=[_req("speech-2", 120, 0)],
    )
    assert entries == {
        "speech-2": {
            "state": "queued",
            "prompt_tokens": 120,
            "completion_tokens": 0,
            "total_tokens": 120,
        }
    }


def test_aborted_running_request_is_marked_aborting() -> None:
    entries = _summarize(
        ["speech-3"],
        running=[_req("speech-3", 100, 4000)],
        aborted={"speech-3"},
    )
    assert entries["speech-3"]["state"] == "aborting"
    assert entries["speech-3"]["completion_tokens"] == 4000


def test_completed_tombstone_has_no_token_entry() -> None:
    entries = _summarize(
        ["speech-4"],
        completed={"speech-4"},
    )
    assert entries == {"speech-4": {"state": "completed"}}


def test_unknown_request_is_not_found() -> None:
    entries = _summarize(["speech-5"])
    assert entries == {"speech-5": {"state": "not_found"}}


def test_aborted_tombstone_after_batch_removal_is_aborting() -> None:
    entries = _summarize(["speech-6"], aborted={"speech-6"})
    assert entries == {"speech-6": {"state": "aborting"}}


def test_multiple_request_ids_map_independently() -> None:
    entries = _summarize(
        ["a", "b", "c"],
        running=[_req("a", 10, 20)],
        queued=[_req("b", 30, 0)],
        completed={"c"},
    )
    assert entries["a"]["state"] == "running"
    assert entries["b"]["state"] == "queued"
    assert entries["c"]["state"] == "completed"


def test_requests_without_rid_are_ignored() -> None:
    entries = _summarize(
        ["speech-7"],
        running=[SimpleNamespace(origin_input_ids=[1], output_ids=[2])],
    )
    assert entries == {"speech-7": {"state": "not_found"}}

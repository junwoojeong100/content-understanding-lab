"""Content Understanding 리소스/역할 전파 지연에 대한 제한적 재시도."""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import TypeVar

from azure.core.exceptions import HttpResponseError

T = TypeVar("T")


def _is_propagation_error(exc: HttpResponseError) -> bool:
    return exc.status_code in {401, 403} or "DeploymentIdNotFound" in str(exc)


def call_with_propagation_retry(
    operation: Callable[[], T],
    *,
    action: str,
    max_attempts: int = 6,
    delay_seconds: int = 20,
) -> T:
    """모델 배포 또는 RBAC 전파 오류만 제한적으로 재시도한다."""

    for attempt in range(1, max_attempts + 1):
        try:
            return operation()
        except HttpResponseError as exc:
            if attempt == max_attempts or not _is_propagation_error(exc):
                raise
            print(f"{action} 전파를 기다립니다 ({attempt}/{max_attempts - 1}, {delay_seconds}초 후 재시도)...")
            time.sleep(delay_seconds)
    raise AssertionError("unreachable")

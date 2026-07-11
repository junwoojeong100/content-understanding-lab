"""작업지시서용 커스텀 분석기를 생성/갱신한다.

작업지시서 필드 스키마(``src.schema``)를 사용해 ``prebuilt-document`` 기반의
커스텀 분석기를 만든다. 분석기는 한 번 만들면 재사용되며, 여러 PDF 를
같은 분석기로 분석할 수 있다.

사용법:
    python -m src.create_analyzer            # 없으면 생성, 있으면 그대로 둠
    python -m src.create_analyzer --recreate # 기존 분석기를 새 스키마/모델로 교체
"""

from __future__ import annotations

import argparse
import time

from azure.ai.contentunderstanding import ContentUnderstandingClient
from azure.ai.contentunderstanding.models import (
    ContentAnalyzer,
    ContentAnalyzerConfig,
)
from azure.core.exceptions import ResourceNotFoundError

from .config import Settings, build_credential, load_settings
from .retry import call_with_propagation_retry
from .schema import SCHEMA_NAME as WORK_ORDER_SCHEMA_NAME
from .schema import build_work_order_schema


def _get_analyzer(client: ContentUnderstandingClient, analyzer_id: str) -> ContentAnalyzer | None:
    try:
        return call_with_propagation_retry(
            lambda: client.get_analyzer(analyzer_id=analyzer_id),
            action="역할",
        )
    except ResourceNotFoundError:
        return None


def _model_mismatches(analyzer: ContentAnalyzer, settings: Settings) -> list[str]:
    """기존 분석기의 모델 설정과 현재 환경 설정 차이를 반환한다."""

    actual = analyzer.models or {}
    expected = {
        "completion": settings.completion_model,
        "embedding": settings.embedding_model,
    }
    return [
        f"{name}={actual.get(name)!r} (기대 {model!r})"
        for name, model in expected.items()
        if actual.get(name) != model
    ]


def _schema_name_mismatch(analyzer: ContentAnalyzer, expected: str) -> str | None:
    """기존 분석기의 필드 스키마 이름이 기대값과 다르면 설명을 반환한다."""

    field_schema = analyzer.field_schema
    actual = field_schema.get("name") if isinstance(field_schema, dict) else getattr(field_schema, "name", None)
    if actual == expected:
        return None
    return f"field_schema.name={actual!r} (기대 {expected!r})"


def _status_value(analyzer: ContentAnalyzer) -> str:
    status = getattr(analyzer, "status", None)
    return str(getattr(status, "value", status) or "").lower()


def _wait_for_analyzer_ready(
    client: ContentUnderstandingClient,
    analyzer_id: str,
    analyzer: ContentAnalyzer,
    *,
    recreate_hint: str,
    max_attempts: int = 24,
    delay_seconds: int = 5,
) -> ContentAnalyzer:
    """생성 중인 분석기는 제한 대기하고 ready 이외 상태는 재사용하지 않는다."""

    current = analyzer
    for attempt in range(1, max_attempts + 1):
        status = _status_value(current)
        if status == "ready":
            return current
        if status != "creating":
            raise SystemExit(
                f"기존 분석기 '{analyzer_id}' 상태가 재사용 불가입니다: {status or 'unknown'}\n"
                f"{recreate_hint}"
            )
        if attempt == max_attempts:
            break
        print(f"분석기 '{analyzer_id}' 생성 완료를 기다립니다 ({attempt}/{max_attempts - 1})...")
        time.sleep(delay_seconds)
        refreshed = _get_analyzer(client, analyzer_id)
        if refreshed is None:
            raise SystemExit(f"대기 중 분석기 '{analyzer_id}' 를 찾을 수 없게 되었습니다. {recreate_hint}")
        current = refreshed
    raise SystemExit(f"분석기 '{analyzer_id}' 가 제한 시간 안에 ready 상태가 되지 않았습니다. {recreate_hint}")


def ensure_analyzer(
    client: ContentUnderstandingClient,
    settings: Settings,
    *,
    recreate: bool = False,
) -> str:
    """분석기가 존재하도록 보장하고 analyzer_id 를 반환한다."""

    analyzer_id = settings.analyzer_id
    existing = _get_analyzer(client, analyzer_id)

    if existing is not None:
        if not recreate:
            existing = _wait_for_analyzer_ready(
                client,
                analyzer_id,
                existing,
                recreate_hint="python -m src.create_analyzer --recreate 로 교체하세요.",
            )
            schema_mismatch = _schema_name_mismatch(existing, WORK_ORDER_SCHEMA_NAME)
            if schema_mismatch:
                raise SystemExit(
                    f"기존 분석기 '{analyzer_id}' 의 스키마가 작업지시서 스키마와 다릅니다: {schema_mismatch}\n"
                    "WORK_ORDER_ANALYZER_ID 를 고유하게 지정하거나 다음 명령으로 교체하세요:\n"
                    "  python -m src.create_analyzer --recreate"
                )
            mismatches = _model_mismatches(existing, settings)
            if mismatches:
                raise SystemExit(
                    f"기존 분석기 '{analyzer_id}' 의 모델 설정이 현재 .env 와 다릅니다: "
                    f"{', '.join(mismatches)}\n"
                    "스키마 변경 내용을 확인한 뒤 다음 명령으로 한 번 재생성하세요:\n"
                    "  python -m src.create_analyzer --recreate"
                )
            print(f"분석기 '{analyzer_id}' 가 이미 존재합니다. (재사용)")
            return analyzer_id
        print(f"기존 분석기 '{analyzer_id}' 를 새 스키마/모델로 교체합니다...")

    print(f"커스텀 분석기 '{analyzer_id}' 를 생성합니다...")

    analyzer = ContentAnalyzer(
        base_analyzer_id="prebuilt-document",
        description="무역회사 작업지시서 데이터 추출 분석기",
        config=ContentAnalyzerConfig(
            enable_ocr=True,
            enable_layout=True,
            enable_formula=False,
            estimate_field_source_and_confidence=True,
            return_details=True,
        ),
        field_schema=build_work_order_schema(),
        models={
            "completion": settings.completion_model,
            "embedding": settings.embedding_model,
        },
    )

    call_with_propagation_retry(
        lambda: client.begin_create_analyzer(
            analyzer_id=analyzer_id,
            resource=analyzer,
            allow_replace=True,
        ).result(),
        action="모델 배포 또는 역할",
    )

    created = call_with_propagation_retry(
        lambda: client.get_analyzer(analyzer_id=analyzer_id),
        action="역할",
    )
    field_count = len(created.field_schema.fields) if created.field_schema and created.field_schema.fields else 0
    print(f"분석기 '{analyzer_id}' 생성 완료. 최상위 필드 {field_count}개.")
    return analyzer_id


def main() -> None:
    parser = argparse.ArgumentParser(description="작업지시서 커스텀 분석기 생성")
    parser.add_argument("--recreate", action="store_true", help="기존 분석기를 새 스키마/모델로 교체")
    args = parser.parse_args()

    settings = load_settings()
    client = ContentUnderstandingClient(endpoint=settings.endpoint, credential=build_credential(settings))
    ensure_analyzer(client, settings, recreate=args.recreate)


if __name__ == "__main__":
    main()

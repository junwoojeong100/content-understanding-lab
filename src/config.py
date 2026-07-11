"""환경 변수 기반 설정 로더.

`.env` 파일(있으면)과 OS 환경 변수에서 Content Understanding 접속 정보를 읽어온다.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Optional
from urllib.parse import urlparse

from dotenv import load_dotenv

load_dotenv()

_ANALYZER_ID_PATTERN = re.compile(r"^[A-Za-z0-9._]{1,64}$")


@dataclass(frozen=True)
class Settings:
    """Content Understanding 실행에 필요한 설정값."""

    endpoint: str
    key: Optional[str]
    analyzer_id: str
    techpack_analyzer_id: str
    completion_model: str
    embedding_model: str

    @property
    def use_api_key(self) -> bool:
        return bool(self.key)


def load_settings() -> Settings:
    """환경 변수에서 설정을 로드한다. 엔드포인트가 없으면 친절한 오류를 던진다."""

    endpoint = os.getenv("CONTENTUNDERSTANDING_ENDPOINT", "").strip()
    if not endpoint:
        raise SystemExit(
            "CONTENTUNDERSTANDING_ENDPOINT 가 설정되지 않았습니다.\n"
            "  1) infra/setup_azure.sh 를 실행해 리소스를 만들고 .env 를 생성하거나\n"
            "  2) .env.example 를 복사해 .env 를 직접 채워주세요."
        )

    parsed_endpoint = urlparse(endpoint)
    if parsed_endpoint.scheme != "https" or not parsed_endpoint.netloc:
        raise SystemExit(
            "CONTENTUNDERSTANDING_ENDPOINT 형식이 올바르지 않습니다.\n"
            "예: https://<리소스이름>.services.ai.azure.com/"
        )

    analyzer_id = os.getenv("WORK_ORDER_ANALYZER_ID", "trade_work_order").strip()
    techpack_analyzer_id = os.getenv("TECHPACK_ANALYZER_ID", "techpack_bom").strip()
    for env_name, value in (
        ("WORK_ORDER_ANALYZER_ID", analyzer_id),
        ("TECHPACK_ANALYZER_ID", techpack_analyzer_id),
    ):
        if not _ANALYZER_ID_PATTERN.fullmatch(value):
            raise SystemExit(
                f"{env_name} 값이 올바르지 않습니다: {value!r}\n"
                "분석기 ID는 영문/숫자/마침표/언더스코어만 사용해 1~64자로 지정하세요."
            )
    if analyzer_id == techpack_analyzer_id:
        raise SystemExit("WORK_ORDER_ANALYZER_ID 와 TECHPACK_ANALYZER_ID 는 서로 다른 값이어야 합니다.")

    completion_model = os.getenv("COMPLETION_MODEL", "gpt-5.2").strip()
    embedding_model = os.getenv("EMBEDDING_MODEL", "text-embedding-3-large").strip()
    if not completion_model or not embedding_model:
        raise SystemExit("COMPLETION_MODEL 과 EMBEDDING_MODEL 은 비워둘 수 없습니다.")

    return Settings(
        endpoint=endpoint,
        key=os.getenv("CONTENTUNDERSTANDING_KEY", "").strip() or None,
        analyzer_id=analyzer_id,
        techpack_analyzer_id=techpack_analyzer_id,
        completion_model=completion_model,
        embedding_model=embedding_model,
    )


def build_credential(settings: Settings):
    """API 키가 있으면 AzureKeyCredential, 없으면 DefaultAzureCredential 을 반환."""

    if settings.key is not None:
        from azure.core.credentials import AzureKeyCredential

        return AzureKeyCredential(settings.key)

    from azure.identity import DefaultAzureCredential

    return DefaultAzureCredential()

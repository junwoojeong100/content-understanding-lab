"""Foundry 리소스의 기본 모델 매핑 설정 (1회성).

Content Understanding 의 prebuilt/custom 분석기에 사용할 gpt-5.2,
gpt-4.1-mini, text-embedding-3-large 배포를 표준 모델명과 prebuilt 모델
별칭에 매핑한다. Foundry 리소스당 1회만 실행하면 된다.

사용법:
    python -m src.setup_defaults
"""

from __future__ import annotations

import argparse
import os

from azure.ai.contentunderstanding import ContentUnderstandingClient

from .config import build_credential, load_settings
from .retry import call_with_propagation_retry


def _deployment_name(env_name: str, default: str) -> str:
    value = os.getenv(env_name, default).strip()
    if not value:
        raise SystemExit(f"{env_name} 은(는) 비워둘 수 없습니다.")
    return value


def configure_defaults() -> None:
    settings = load_settings()
    client = ContentUnderstandingClient(endpoint=settings.endpoint, credential=build_credential(settings))

    completion_deployment = _deployment_name("GPT_5_2_DEPLOYMENT", "gpt-5.2")
    mini_deployment = _deployment_name("GPT_4_1_MINI_DEPLOYMENT", "gpt-4.1-mini")
    embedding_deployment = _deployment_name(
        "TEXT_EMBEDDING_3_LARGE_DEPLOYMENT",
        "text-embedding-3-large",
    )
    model_deployments = {
        "gpt-5.2": completion_deployment,
        "gpt-4.1-mini": mini_deployment,
        "text-embedding-3-large": embedding_deployment,
        "prebuilt-analyzer-completion": completion_deployment,
        "prebuilt-analyzer-completion-mini": mini_deployment,
        "prebuilt-analyzer-embedding": embedding_deployment,
    }

    print("기본 모델 매핑을 설정합니다...")
    updated = call_with_propagation_retry(
        lambda: client.update_defaults(model_deployments=model_deployments),
        action="모델 배포 또는 역할",
    )

    print("설정 완료. 현재 매핑:")
    for model_name, deployment in (updated.model_deployments or {}).items():
        print(f"  {model_name} -> {deployment}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Content Understanding 기본 모델 매핑 설정")
    parser.parse_args()
    configure_defaults()


if __name__ == "__main__":
    main()

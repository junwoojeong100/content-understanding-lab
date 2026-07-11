#!/usr/bin/env bash
#
# setup_azure.sh 로 만든 리소스를 정리한다. (과금 중단)
# 기본적으로 리소스 그룹 전체를 삭제한다.
#
# 사용법:
#   ./infra/teardown_azure.sh
#   RESOURCE_GROUP=rg-trade-content-understanding ./infra/teardown_azure.sh
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

read_env_value() {
  local key="$1" value
  if [ -f "$ENV_FILE" ]; then
    value="$(
      sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*(.*)$/\2/p" \
        "$ENV_FILE" 2>/dev/null | tail -n1 | tr -d '\r'
    )"
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$value" in
      \"*)
        value="$(printf '%s' "$value" | sed -E 's/^"([^"]*)"[[:space:]]*(#.*)?$/\1/')"
        ;;
      \'*)
        value="$(printf '%s' "$value" | sed -E "s/^'([^']*)'[[:space:]]*(#.*)?$/\\1/")"
        ;;
      *)
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')"
        ;;
    esac
    printf '%s' "$value"
  fi
}

TARGET_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(read_env_value AZURE_SUBSCRIPTION_ID)}"
RESOURCE_GROUP="${RESOURCE_GROUP:-$(read_env_value AZURE_RESOURCE_GROUP)}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-trade-content-understanding}"

if ! command -v az >/dev/null 2>&1; then
  echo "[오류] Azure CLI(az) 가 설치되어 있지 않습니다. https://aka.ms/azcli 참고." >&2
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  echo "[오류] Azure 에 로그인되어 있지 않습니다. 먼저 'az login' 을 실행하세요." >&2
  exit 1
fi
if [ -n "$TARGET_SUBSCRIPTION_ID" ]; then
  if ! SUBSCRIPTION_ID="$(
    az account show --subscription "$TARGET_SUBSCRIPTION_ID" --query id -o tsv 2>/dev/null | tr -d '\r'
  )"; then
    echo "[오류] 저장/지정된 Azure 구독을 현재 로그인에서 찾을 수 없습니다: $TARGET_SUBSCRIPTION_ID" >&2
    exit 1
  fi
else
  SUBSCRIPTION_ID="$(az account show --query id -o tsv | tr -d '\r')"
fi
SUBSCRIPTION_NAME="$(az account show --subscription "$SUBSCRIPTION_ID" --query name -o tsv | tr -d '\r')"
echo "현재 구독: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
if [ "$(az group exists --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID" | tr -d '\r')" != "true" ]; then
  echo "현재 구독에 리소스 그룹 '$RESOURCE_GROUP' 이(가) 없습니다."
  exit 0
fi

echo "리소스 그룹 '$RESOURCE_GROUP' 을(를) 삭제합니다. 포함된 모든 리소스가 제거됩니다."
read -r -p "계속하려면 리소스 그룹 이름 '$RESOURCE_GROUP' 입력: " CONFIRM
if [ "$CONFIRM" != "$RESOURCE_GROUP" ]; then
  echo "취소되었습니다."
  exit 0
fi

az group delete --name "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID" --yes --no-wait
echo "삭제 요청 완료(백그라운드 진행). 상태 확인:"
echo "  az group exists -n $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID"
echo "참고: Foundry 리소스는 최대 48시간 soft-delete 상태로 남습니다."
echo "      같은 리소스 그룹·리전·계정 이름으로 setup_azure.sh 를 다시 실행하면 자동 복구합니다."

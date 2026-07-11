#!/usr/bin/env bash
#
# Azure AI Content Understanding 용 리소스를 현재 연결된 구독에 생성한다.
#
#   1) 리소스 그룹
#   2) Microsoft Foundry(=AIServices) 리소스 (custom subdomain 포함)
#   3) 모델 배포: gpt-5.2, gpt-4.1-mini, text-embedding-3-large
#   4) 본인 계정에 'Cognitive Services Content Understanding Owner' 역할 부여
#   5) 프로젝트 루트에 .env 생성 (엔드포인트/배포 이름)
#
# 사용법:
#   ./infra/setup_azure.sh
#   LOCATION=swedencentral ACCOUNT_NAME=my-foundry ./infra/setup_azure.sh
#
# 사전 요구사항: az CLI 로그인(az login), 구독에 리소스 생성 권한(Contributor 이상).
set -euo pipefail

# Windows Git Bash가 /subscriptions/... ARM ID를 로컬 경로로 바꾸지 않도록 한다.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# ── 설정값 (환경 변수로 재정의 가능) ─────────────────────────────────────
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
LOCATION="${LOCATION:-$(read_env_value AZURE_LOCATION)}"
LOCATION="${LOCATION:-eastus2}"
SAVED_ACCOUNT_NAME="$(read_env_value AZURE_ACCOUNT_NAME)"
SAVED_PROJECT_NAME="$(read_env_value AZURE_PROJECT_NAME)"
WORK_ORDER_ANALYZER_ID="${WORK_ORDER_ANALYZER_ID:-$(read_env_value WORK_ORDER_ANALYZER_ID)}"
WORK_ORDER_ANALYZER_ID="${WORK_ORDER_ANALYZER_ID:-trade_work_order}"
TECHPACK_ANALYZER_ID="${TECHPACK_ANALYZER_ID:-$(read_env_value TECHPACK_ANALYZER_ID)}"
TECHPACK_ANALYZER_ID="${TECHPACK_ANALYZER_ID:-techpack_bom}"
GPT_5_2_DEPLOYMENT="${GPT_5_2_DEPLOYMENT:-$(read_env_value GPT_5_2_DEPLOYMENT)}"
GPT_5_2_DEPLOYMENT="${GPT_5_2_DEPLOYMENT:-gpt-5.2}"
GPT_4_1_MINI_DEPLOYMENT="${GPT_4_1_MINI_DEPLOYMENT:-$(read_env_value GPT_4_1_MINI_DEPLOYMENT)}"
GPT_4_1_MINI_DEPLOYMENT="${GPT_4_1_MINI_DEPLOYMENT:-gpt-4.1-mini}"
TEXT_EMBEDDING_3_LARGE_DEPLOYMENT="${TEXT_EMBEDDING_3_LARGE_DEPLOYMENT:-$(read_env_value TEXT_EMBEDDING_3_LARGE_DEPLOYMENT)}"
TEXT_EMBEDDING_3_LARGE_DEPLOYMENT="${TEXT_EMBEDDING_3_LARGE_DEPLOYMENT:-text-embedding-3-large}"
CONTENT_UNDERSTANDING_ROLE="Cognitive Services Content Understanding Owner"

for analyzer_id in "$WORK_ORDER_ANALYZER_ID" "$TECHPACK_ANALYZER_ID"; do
  if ! [[ "$analyzer_id" =~ ^[A-Za-z0-9._]{1,64}$ ]]; then
    echo "[오류] 분석기 ID 형식이 올바르지 않습니다: '$analyzer_id'" >&2
    echo "       영문/숫자/마침표/언더스코어만 사용해 1~64자로 지정하세요." >&2
    exit 1
  fi
done
if [ "$WORK_ORDER_ANALYZER_ID" = "$TECHPACK_ANALYZER_ID" ]; then
  echo "[오류] WORK_ORDER_ANALYZER_ID 와 TECHPACK_ANALYZER_ID 는 서로 다른 값이어야 합니다." >&2
  exit 1
fi

# ── 사전 점검: az CLI 설치 및 로그인 확인 ───────────────────────────────
if ! command -v az >/dev/null 2>&1; then
  echo "[오류] Azure CLI(az) 가 설치되어 있지 않습니다. https://aka.ms/azcli 참고." >&2
  exit 1
fi
# 실행 가능한 Python 3.10+를 고른다. WindowsApps shim 등 실패하는 명령은 건너뛴다.
PYTHON_BIN=""
for python_candidate in python3 python; do
  candidate_path="$(command -v "$python_candidate" 2>/dev/null || true)"
  if [ -n "$candidate_path" ] && "$candidate_path" -c \
      'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
    PYTHON_BIN="$candidate_path"
    break
  fi
done
if [ -z "$PYTHON_BIN" ]; then
  echo "[오류] 실행 가능한 Python 3.10+ 명령(python3 또는 python)이 필요합니다." >&2
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  echo "[오류] Azure 에 로그인되어 있지 않습니다. 먼저 'az login' 을 실행하세요." >&2
  echo "       구독이 여러 개면: az account set --subscription <구독ID 또는 이름>" >&2
  exit 1
fi
ACCOUNT_CREATE_HELP="$(az cognitiveservices account create -h 2>/dev/null || true)"
if ! grep -q -- "--allow-project-management" <<< "$ACCOUNT_CREATE_HELP"; then
  echo "[오류] 현재 Azure CLI 가 Foundry 프로젝트 관리 옵션을 지원하지 않습니다." >&2
  echo "       'az upgrade' 또는 https://aka.ms/azcli 의 최신 설치본으로 업데이트하세요." >&2
  exit 1
fi
if ! az cognitiveservices account project -h >/dev/null 2>&1; then
  echo "[오류] 현재 Azure CLI 에 'az cognitiveservices account project' 명령이 없습니다." >&2
  echo "       'az upgrade' 또는 https://aka.ms/azcli 의 최신 설치본으로 업데이트하세요." >&2
  exit 1
fi

# 전역적으로 고유한 이름이 필요하므로 구독 ID 일부를 접미사로 사용
if [ -n "$TARGET_SUBSCRIPTION_ID" ]; then
  if ! SUB_ID="$(az account show --subscription "$TARGET_SUBSCRIPTION_ID" --query id -o tsv 2>/dev/null | tr -d '\r')"; then
    echo "[오류] 저장/지정된 Azure 구독을 현재 로그인에서 찾을 수 없습니다: $TARGET_SUBSCRIPTION_ID" >&2
    exit 1
  fi
else
  SUB_ID="$(az account show --query id -o tsv | tr -d '\r')"
fi
az_sub() {
  az "$@" --subscription "$SUB_ID"
}
az_tsv() {
  az_sub "$@" -o tsv | tr -d '\r'
}

SUFFIX="$(printf '%s' "$SUB_ID" | tr -dc 'a-f0-9' | cut -c1-8)"
ACCOUNT_NAME="${ACCOUNT_NAME:-$SAVED_ACCOUNT_NAME}"
ACCOUNT_NAME="${ACCOUNT_NAME:-tradecu${SUFFIX}}"

# Content Understanding GA 지원 리전
SUPPORTED_REGIONS="australiaeast eastus eastus2 japaneast northeurope southcentralus southeastasia swedencentral uksouth westeurope westus westus3"

echo "=========================================================="
echo " Azure AI Content Understanding 리소스 생성"
echo "=========================================================="
echo "  구독        : $(az_tsv account show --query name) ($SUB_ID)"
echo "  리소스그룹  : $RESOURCE_GROUP"
echo "  리전        : $LOCATION"
echo "  리소스 이름 : $ACCOUNT_NAME"
echo "----------------------------------------------------------"

if ! grep -qw "$LOCATION" <<< "$SUPPORTED_REGIONS"; then
  echo "[오류] '$LOCATION' 은(는) Content Understanding GA 지원 리전이 아닙니다." >&2
  echo "       지원 리전: $SUPPORTED_REGIONS" >&2
  exit 1
fi

# ── 0) 리소스 공급자 등록 ───────────────────────────────────────────────
echo "[0/5] 리소스 공급자(Microsoft.CognitiveServices) 등록 확인..."
if ! az_sub provider register --namespace Microsoft.CognitiveServices --wait --only-show-errors -o none; then
  echo "[오류] Microsoft.CognitiveServices 리소스 공급자를 등록하지 못했습니다." >&2
  exit 1
fi

# ── 1) 리소스 그룹 ─────────────────────────────────────────────────────
echo "[1/5] 리소스 그룹 생성/확인..."
az_sub group create --name "$RESOURCE_GROUP" --location "$LOCATION" --only-show-errors -o none

# ── 2) Foundry(AIServices) 리소스 ──────────────────────────────────────
echo "[2/5] Foundry(AIServices) 리소스 생성/확인..."
if az_sub cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "      이미 존재함: $ACCOUNT_NAME"
else
  DELETED_ACCOUNTS_JSON="$(az_sub cognitiveservices account list-deleted --only-show-errors -o json 2>/dev/null || printf '[]')"
  DELETED_ACCOUNT_ID="$(
    printf '%s' "$DELETED_ACCOUNTS_JSON" \
      | ACCOUNT_NAME="$ACCOUNT_NAME" RESOURCE_GROUP="$RESOURCE_GROUP" LOCATION="$LOCATION" "$PYTHON_BIN" -c '
import json
import os
import sys

name = os.environ["ACCOUNT_NAME"].lower()
group = os.environ["RESOURCE_GROUP"].lower()
location = os.environ["LOCATION"].lower()
suffix = f"/locations/{location}/resourcegroups/{group}/deletedaccounts/{name}"
for account in json.load(sys.stdin):
    account_id = str(account.get("id") or "")
    if account_id.lower().endswith(suffix):
        print(account_id)
        break
'
  )"

  if [ -n "$DELETED_ACCOUNT_ID" ]; then
    echo "      동일 이름의 soft-delete 리소스를 복구합니다: $ACCOUNT_NAME"
    if ! RECOVER_ERROR="$(az_sub cognitiveservices account recover \
        --name "$ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --only-show-errors -o none 2>&1)"; then
      echo "[오류] soft-delete 리소스를 복구하지 못했습니다." >&2
      printf '%s\n' "$RECOVER_ERROR" | sed 's/^/       /' >&2
      echo "       다른 ACCOUNT_NAME 을 사용하거나 삭제된 리소스를 수동 purge 한 뒤 다시 실행하세요." >&2
      exit 1
    fi
    for _ in $(seq 1 30); do
      if az_sub cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
        break
      fi
      sleep 5
    done
    if ! az_sub cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
      echo "[오류] 복구 요청 후 리소스를 확인하지 못했습니다: $ACCOUNT_NAME" >&2
      exit 1
    fi
    echo "      복구 완료: $ACCOUNT_NAME"
  else
    az_sub cognitiveservices account create \
      --name "$ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --kind AIServices \
      --sku S0 \
      --location "$LOCATION" \
      --custom-domain "$ACCOUNT_NAME" \
      --allow-project-management true \
      --yes \
      --only-show-errors -o none
    echo "      생성 완료: $ACCOUNT_NAME (Foundry 리소스, 프로젝트 관리 활성화)"
  fi
fi

EXISTING_KIND="$(az_tsv cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query kind)"
EXISTING_LOCATION="$(az_tsv cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query location)"
if [ "$EXISTING_KIND" != "AIServices" ]; then
  echo "[오류] '$ACCOUNT_NAME' 은(는) AIServices 리소스가 아닙니다(kind=$EXISTING_KIND)." >&2
  exit 1
fi
if [ "$EXISTING_LOCATION" != "$LOCATION" ]; then
  echo "[오류] 기존 리소스 '$ACCOUNT_NAME' 의 리전은 '$EXISTING_LOCATION' 입니다." >&2
  echo "       LOCATION=$EXISTING_LOCATION 로 다시 실행하거나 다른 ACCOUNT_NAME 을 사용하세요." >&2
  exit 1
fi

ACCOUNT_ID="$(az_tsv cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query id)"
echo "      로컬 키 인증 비활성화(Entra ID 전용)..."
if ! az_sub resource update --ids "$ACCOUNT_ID" --set properties.disableLocalAuth=true --only-show-errors -o none; then
  echo "[오류] 로컬 키 인증을 비활성화하지 못했습니다." >&2
  exit 1
fi

# Foundry 프로젝트 생성(있으면 건너뜀) — Foundry 포털(ai.azure.com) 노출용
PROJECT_NAME="${PROJECT_NAME:-$SAVED_PROJECT_NAME}"
PROJECT_NAME="${PROJECT_NAME:-${ACCOUNT_NAME}-project}"
ALLOW_PROJECT_MANAGEMENT="$(az_tsv cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --query properties.allowProjectManagement)"
if [ "$ALLOW_PROJECT_MANAGEMENT" != "true" ]; then
  echo "      [참고] 기존 리소스는 프로젝트 관리가 비활성화되어 프로젝트 생성을 건너뜁니다."
  echo "             Content Understanding API 사용에는 영향이 없습니다."
elif az_sub cognitiveservices account project show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --project-name "$PROJECT_NAME" >/dev/null 2>&1; then
  echo "      프로젝트 이미 존재: $PROJECT_NAME"
else
  if PROJECT_ERROR="$(az_sub cognitiveservices account project create \
      -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" \
      --project-name "$PROJECT_NAME" --location "$LOCATION" \
      --only-show-errors -o none 2>&1)"; then
    echo "      Foundry 프로젝트 생성: $PROJECT_NAME"
  else
    echo "      [참고] 프로젝트 생성 실패. Content Understanding API 사용에는 영향이 없습니다."
    printf '%s\n' "$PROJECT_ERROR" | sed 's/^/             /'
  fi
fi


# ── 3) 모델 배포 ───────────────────────────────────────────────────────
deploy_model() {
  local model="$1" deployment="$2" capacity_cap="$3"

  if az_sub cognitiveservices account deployment show \
        -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --deployment-name "$deployment" >/dev/null 2>&1; then
    local existing_model existing_state
    existing_model="$(az_tsv cognitiveservices account deployment show \
      -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --deployment-name "$deployment" \
      --query "properties.model.name")"
    existing_state="$(az_tsv cognitiveservices account deployment show \
      -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --deployment-name "$deployment" \
      --query "properties.provisioningState")"
    if [ "$existing_model" != "$model" ]; then
      echo "      [경고] 배포 '$deployment' 은(는) 요청 모델 '$model' 이 아니라 '$existing_model' 을 가리킵니다."
      return 1
    fi
    if [ "$existing_state" != "Succeeded" ]; then
      echo "      [경고] 배포 '$deployment' 상태가 Succeeded 가 아닙니다: $existing_state"
      return 1
    fi
    echo "      배포 이미 존재: $deployment (model=$model)"
    return 0
  fi

  # 모델의 최신 버전과 시도할 SKU 후보 목록(선호 순서)을 가져온다.
  # 출력 1행: version, 이후 각 행: "sku<TAB>capacity"
  local plan
  plan=$(az_sub cognitiveservices account list-models -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" -o json \
        | MODEL="$model" CAP="$capacity_cap" "$PYTHON_BIN" -c '
import json, os, sys
models = json.load(sys.stdin)
name, cap = os.environ["MODEL"], int(os.environ["CAP"])
cand = [m for m in models if m.get("name") == name and m.get("format") == "OpenAI"]
if not cand:
    print("NONE"); sys.exit(0)
cand.sort(key=lambda m: m.get("version", ""))
m = cand[-1]
avail = {s.get("name"): (s.get("capacity") or {}) for s in m.get("skus", [])}
pref = ["GlobalStandard", "Standard", "DataZoneStandard"]
# 실습 스크립트에서는 사용량 기반 Standard 계열만 허용한다.
# ProvisionedManaged 계열은 예약 용량 비용이 발생할 수 있어 자동 생성하지 않는다.
ordered = [s for s in pref if s in avail]
sys.stdout.write((m.get("version") or "") + "\n")
for sku in ordered:
    c = avail[sku]
    default_cap = c.get("default") or c.get("maximum") or 1
    cap_final = min(int(default_cap), cap) if default_cap else cap
    sys.stdout.write(sku + "\t" + str(cap_final) + "\n")
')

  if [ "$plan" = "NONE" ] || [ -z "$plan" ]; then
    echo "      [경고] 리전 '$LOCATION' 에서 모델 '$model' 을(를) 찾을 수 없습니다. 다른 리전을 시도하세요."
    return 1
  fi

  local version
  version="$(printf '%s\n' "$plan" | head -n1)"

  # SKU 후보를 순서대로 시도하고, 할당량(quota) 부족 시 다음 SKU 로 폴백
  local line sku capacity
  while IFS=$'\t' read -r sku capacity; do
    [ -z "$sku" ] && continue
    echo "      배포 시도: $deployment (model=$model, version=$version, sku=$sku, capacity=$capacity)"
    if DEPLOY_ERROR="$(az_sub cognitiveservices account deployment create \
        -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" \
        --deployment-name "$deployment" \
        --model-name "$model" --model-version "$version" --model-format OpenAI \
        --sku-name "$sku" --sku-capacity "$capacity" \
        --only-show-errors -o none 2>&1)"; then
      echo "      배포 성공: $deployment ($sku)"
      return 0
    fi
    echo "      -> $sku 실패. 다음 SKU 시도..."
    printf '%s\n' "$DEPLOY_ERROR" | sed 's/^/         /'
  done < <(printf '%s\n' "$plan" | tail -n +2)

  echo "      [경고] '$deployment'($model) 배포 실패. 할당량/정책/리전 가용성을 확인하세요."
  return 1
}

echo "[3/5] 모델 배포 (gpt-5.2, gpt-4.1-mini, text-embedding-3-large)..."
deploy_model "gpt-5.2" "$GPT_5_2_DEPLOYMENT" 30 || true
deploy_model "gpt-4.1-mini" "$GPT_4_1_MINI_DEPLOYMENT" 30 || true
deploy_model "text-embedding-3-large" "$TEXT_EMBEDDING_3_LARGE_DEPLOYMENT" 50 || true

# 배포 결과 검증 — 누락 모델을 수집(성공으로 오인하지 않도록)
echo "      배포 상태 확인..."
MISSING_MODELS=""
check_deployment() {
  local model="$1" deployment="$2" state actual_model
  state="$(az_tsv cognitiveservices account deployment show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --deployment-name "$deployment" --query "properties.provisioningState" 2>/dev/null || true)"
  actual_model="$(az_tsv cognitiveservices account deployment show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" --deployment-name "$deployment" --query "properties.model.name" 2>/dev/null || true)"
  if [ "$state" = "Succeeded" ] && [ "$actual_model" = "$model" ]; then
    echo "        [OK]   $deployment ($model)"
  else
    echo "        [누락/불일치] $deployment (기대=$model, 실제=${actual_model:-없음}, 상태=${state:-없음})"
    MISSING_MODELS="$MISSING_MODELS $model/$deployment"
  fi
}
check_deployment "gpt-5.2" "$GPT_5_2_DEPLOYMENT"
check_deployment "gpt-4.1-mini" "$GPT_4_1_MINI_DEPLOYMENT"
check_deployment "text-embedding-3-large" "$TEXT_EMBEDDING_3_LARGE_DEPLOYMENT"

# ── 4) 역할 부여 ───────────────────────────────────────────────────────
# 분석기 생성/삭제/분석과 defaults 갱신에 필요한 Content Understanding 전용 역할.
echo "[4/5] '$CONTENT_UNDERSTANDING_ROLE' 역할 부여..."
USER_OID="$(
  az_tsv account get-access-token --resource https://management.azure.com/ --query accessToken 2>/dev/null \
    | "$PYTHON_BIN" -c '
import base64
import json
import sys

token = sys.stdin.read().strip()
if token:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    print(json.loads(base64.urlsafe_b64decode(payload)).get("oid", ""))
' 2>/dev/null || true
)"
ROLE_OK=0
if [ -n "$USER_OID" ]; then
  ROLE_COUNT="$(az_tsv role assignment list --assignee "$USER_OID" --scope "$ACCOUNT_ID" --include-inherited \
       --include-groups \
       --query "length([?roleDefinitionName=='$CONTENT_UNDERSTANDING_ROLE'])" 2>/dev/null || true)"
  if [ "${ROLE_COUNT:-0}" -gt 0 ]; then
    echo "      이미 부여되어 있습니다."
    ROLE_OK=1
  elif ROLE_ERROR="$(az_sub role assignment create \
       --assignee-object-id "$USER_OID" --assignee-principal-type User \
       --role "$CONTENT_UNDERSTANDING_ROLE" --scope "$ACCOUNT_ID" \
       --only-show-errors -o none 2>&1)"; then
    echo "      부여 완료 (전파에 1~2분 소요될 수 있음)"
    ROLE_OK=1
  else
    echo "      [경고] 역할을 자동 부여하지 못했습니다."
    printf '%s\n' "$ROLE_ERROR" | sed 's/^/             /'
    echo "             역할 부여에는 Owner, User Access Administrator 또는"
    echo "             Role Based Access Control Administrator 권한이 필요합니다."
    echo "             관리자에게 '$CONTENT_UNDERSTANDING_ROLE' 역할을 요청하세요."
  fi
else
  echo "      [경고] 로그인 사용자 ID 조회 실패 — 수동으로 '$CONTENT_UNDERSTANDING_ROLE' 역할을 부여하세요."
fi

# ── 5) .env 작성 ───────────────────────────────────────────────────────
echo "[5/5] .env 파일 작성..."
ENDPOINT="$(az_tsv cognitiveservices account show -n "$ACCOUNT_NAME" -g "$RESOURCE_GROUP" \
  --query 'properties.endpoints."Content Understanding"')"
if [ -z "$ENDPOINT" ]; then
  echo "[오류] 리소스에서 Content Understanding 엔드포인트를 찾지 못했습니다." >&2
  exit 1
fi

EXTRA_ENV_FILE=""
if [ -f "$ENV_FILE" ]; then
  EXTRA_ENV_FILE="$(mktemp)"
  tr -d '\r' < "$ENV_FILE" \
    | grep -Ev '^[[:space:]]*(export[[:space:]]+)?(AZURE_SUBSCRIPTION_ID|AZURE_RESOURCE_GROUP|AZURE_LOCATION|AZURE_ACCOUNT_NAME|AZURE_PROJECT_NAME|CONTENTUNDERSTANDING_ENDPOINT|CONTENTUNDERSTANDING_KEY|WORK_ORDER_ANALYZER_ID|TECHPACK_ANALYZER_ID|GPT_5_2_DEPLOYMENT|GPT_4_1_DEPLOYMENT|GPT_4_1_MINI_DEPLOYMENT|TEXT_EMBEDDING_3_LARGE_DEPLOYMENT|COMPLETION_MODEL|EMBEDDING_MODEL)[[:space:]]*=' \
    | grep -Ev '^[[:space:]]*(#|$)' > "$EXTRA_ENV_FILE" || true
fi

cat > "$ENV_FILE" <<EOF
# infra/setup_azure.sh 가 자동 생성한 파일입니다.
AZURE_SUBSCRIPTION_ID=${SUB_ID}
AZURE_RESOURCE_GROUP=${RESOURCE_GROUP}
AZURE_LOCATION=${LOCATION}
AZURE_ACCOUNT_NAME=${ACCOUNT_NAME}
AZURE_PROJECT_NAME=${PROJECT_NAME}

CONTENTUNDERSTANDING_ENDPOINT=${ENDPOINT}

# 인증: DefaultAzureCredential(az login) 사용.
# '$CONTENT_UNDERSTANDING_ROLE' 역할이 필요하며 로컬 키 인증은 비활성화되어 있습니다.
CONTENTUNDERSTANDING_KEY=

WORK_ORDER_ANALYZER_ID=${WORK_ORDER_ANALYZER_ID}
TECHPACK_ANALYZER_ID=${TECHPACK_ANALYZER_ID}

GPT_5_2_DEPLOYMENT=${GPT_5_2_DEPLOYMENT}
GPT_4_1_MINI_DEPLOYMENT=${GPT_4_1_MINI_DEPLOYMENT}
TEXT_EMBEDDING_3_LARGE_DEPLOYMENT=${TEXT_EMBEDDING_3_LARGE_DEPLOYMENT}

COMPLETION_MODEL=gpt-5.2
EMBEDDING_MODEL=text-embedding-3-large
EOF
if [ -n "$EXTRA_ENV_FILE" ] && [ -s "$EXTRA_ENV_FILE" ]; then
  {
    echo ""
    echo "# 기존 .env 의 사용자 정의 변수"
    cat "$EXTRA_ENV_FILE"
  } >> "$ENV_FILE"
fi
if [ -n "$EXTRA_ENV_FILE" ]; then
  rm -f "$EXTRA_ENV_FILE"
fi
chmod 600 "$ENV_FILE" 2>/dev/null || true

echo "=========================================================="
SETUP_OK=1
if [ -n "$MISSING_MODELS" ]; then
  echo " ⚠ 경고: 일부 필수 모델이 배포되지 않았습니다 →${MISSING_MODELS}"
  echo "   리전 할당량, Azure Policy, 모델 가용성을 확인하세요:"
  echo "     - 'az cognitiveservices usage list -l $LOCATION -o table' 로 할당량 확인"
  echo "     - 다른 리전으로 재실행: LOCATION=<region> ACCOUNT_NAME=<새-고유이름> bash infra/setup_azure.sh"
  echo "     - 포털에서 해당 모델 할당량 증설 요청"
  echo "   ※ 누락 모델을 배포하기 전에는 setup_defaults / 추출이 실패할 수 있습니다."
  echo "----------------------------------------------------------"
  SETUP_OK=0
fi
if [ "$ROLE_OK" != "1" ]; then
  echo " ⚠ 경고: '$CONTENT_UNDERSTANDING_ROLE' 역할이 부여되지 않았습니다."
  echo "   역할이 없으면 setup_defaults / 추출이 401/403 으로 실패합니다."
  echo "   역할 부여 권한이 있으면 본 스크립트를 다시 실행하거나 관리자에게 요청하세요."
  echo "----------------------------------------------------------"
  SETUP_OK=0
fi
if [ "$SETUP_OK" = "1" ]; then
  echo " 완료!  엔드포인트: $ENDPOINT"
else
  echo " 설정 미완료. 위 경고를 해결한 뒤 스크립트를 다시 실행하세요."
fi
echo "=========================================================="
echo "다음 단계:"
echo "  1) \"$PYTHON_BIN\" -m venv .venv && source .venv/bin/activate"
echo "     # Windows(Git Bash): python -m venv .venv && source .venv/Scripts/activate"
echo "  2) pip install -r requirements.txt"
echo "  3) python -m src.setup_defaults          # 모델 매핑(1회)"
echo "  4) python -m src.extract_work_order 작업지시서.pdf"
echo ""
echo "참고: 3)과 4)는 새 모델/역할 전파가 늦으면 최대 약 2분간 자동 재시도합니다."
if [ "$SETUP_OK" != "1" ]; then
  exit 1
fi

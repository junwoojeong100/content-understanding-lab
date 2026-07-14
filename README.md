# Azure AI Content Understanding 실습: 작업지시서 JSON + TechPack BOM Excel

**Azure AI Content Understanding**(현재 Microsoft Learn 표기:
**Azure Content Understanding in Foundry Tools**, 이하 Content Understanding)으로 다음 두 문서
자동화 흐름을 실습하는 Python 프로젝트입니다.

- **작업지시서(Work Order)** PDF → 구조화 JSON + 서비스 원본 JSON
- **의류 TechPack BOM** PDF → 구조화 JSON + 고객 양식 Excel(12개 컬럼)

관련 Foundry 리소스, 모델 배포, Entra ID 역할, `.env`를 준비하는 Azure CLI 스크립트도 포함합니다.

## 문서 읽는 순서

| 하고 싶은 일 | 읽을 곳 |
| --- | --- |
| 프로젝트를 처음 실행 | 아래 [빠른 시작](#빠른-시작) |
| 결과 JSON과 Excel 이해 | 아래 [결과 파일 이해하기](#결과-파일-이해하기) |
| 여러 문서 형식·사용자 피드백·Copilot 활용 | [초보자를 위한 피드백 루프 가이드](docs/feedback-loop-guide.md) |

처음 실습하는 분은 **빠른 시작 0→4단계**만 먼저 실행해도 됩니다. 스키마와 후처리의 자세한 내부
구조는 결과를 직접 확인한 뒤 읽는 편이 이해하기 쉽습니다.

## 한눈에 보는 동작 방식

```
작업지시서.pdf
      │
      ▼
 [커스텀 분석기]  ← ① src/schema.py 필드 스키마 (서비스가 fields 생성)
      │            Azure AI Content Understanding (Microsoft Foundry)
      ▼
 서비스 RAW 응답 ─────────────────────────▶ output/작업지시서.raw.json (원본 전체 보존)
      │
      ▼ ② _simplify_field() 평탄화 후처리 (extract_work_order.py)
 output/작업지시서.json  ← 정제된 구조화 필드 + 마크다운 + 표
```

- **커스텀 분석기**로 작업지시서에 특화된 필드(문서정보·거래처·무역조건·선적·포장·품목 내역·합계 등)를 구조화 추출합니다.
- 동시에 **원본 JSON 전체**(마크다운·레이아웃·표 포함)를 저장하므로 스키마에 없는 데이터도 보존됩니다.

## 결과 파일 이해하기

| 결과 파일 | 쉬운 설명 | 언제 확인하나 |
| --- | --- | --- |
| `*.raw.json` | Azure 서비스가 돌려준 전체 원본 결과 | 누락 원인, 표, 위치, 신뢰도를 자세히 볼 때 |
| `*.json` | 실제 값만 보기 쉽게 정리한 결과 | 앱이나 다른 시스템에서 데이터를 사용할 때 |
| `*.xlsx` | 고객이 원하는 행·열로 변환한 Excel | TechPack의 최종 결과를 확인할 때 |

핵심 흐름은 두 단계입니다.

1. 작업지시서는 `src/schema.py`, TechPack은 `src/techpack_schema.py`에서 **무엇을 찾을지** 정합니다.
2. 추출 코드는 복잡한 결과에서 **실제 값만 꺼내기 쉽게** 정리하고, TechPack은 Excel 행으로 한 번 더 변환합니다.

RAW 필드, 신뢰도, 스키마와 후처리의 수정 기준은
[피드백 루프 가이드](docs/feedback-loop-guide.md#7-문제가-생긴-위치를-찾는-네-가지-질문)에서
예제와 함께 설명합니다.

## 사전 요구사항

- **Azure 구독** 과 권한:
  - 리소스/모델 생성: Azure RBAC **Contributor** 이상
  - 역할 자동 부여: Azure RBAC **Owner**, **User Access Administrator** 또는
    **Role Based Access Control Administrator**.
  - 이 실습의 분석기 생성·갱신·분석과 설정 작업을 한 번에 진행할 수 있도록 스크립트가 전용 역할 중
    전체 권한인 `Cognitive Services Content Understanding Owner`를 본인에게 부여합니다.
    이미 만들어진 분석기 실행만 필요하면 `Cognitive Services Content Understanding Reader`,
    생성·갱신까지 필요하면 `Cognitive Services Content Understanding Contributor` 역할도 사용할 수 있습니다.
- **Azure CLI(`az`)** 설치 — https://aka.ms/azcli
- **Python 3.10+**
- **셸**: macOS/Linux 는 기본 터미널(bash). **Windows 는 WSL 또는 Git Bash** 에서 실행하세요(`infra/*.sh` 는 bash 스크립트).
- Content Understanding GA 리전(아래 중 하나, 기본값 `eastus2`): `eastus`, `eastus2`, `westus`, `westus3`,
  `southcentralus`, `southeastasia`, `northeurope`, `westeurope`, `swedencentral`, `uksouth`,
  `japaneast`, `australiaeast`

## 빠른 시작

> 아래 0→4 단계를 순서대로 실행하면 작업지시서 흐름이 완료됩니다. TechPack은 5단계에서 선택 실행합니다.
> 처음부터 끝까지 복붙용 한 묶음은 맨 아래
> [전체 순서 요약](#전체-순서-요약-복붙용) 을 참고하세요.

### 0) 사전 준비 — 로그인 & 코드 받기

```bash
# 코드 가져오기(이미 받았다면 생략)
git clone https://github.com/junwoojeong100/azure-ai-content-understanding-labs.git
cd azure-ai-content-understanding-labs

# Azure 로그인
az login
# 구독이 여러 개면 사용할 구독을 선택
az account set --subscription "<구독 ID 또는 이름>"
az account show --query name -o tsv      # 현재 구독 확인
```

### 1) Azure 리소스 생성

첫 실행은 현재 로그인된 구독에 Foundry 리소스 + 모델 배포 + 전용 역할 부여 + `.env` 생성을 한 번에 수행합니다.
이후에는 `.env`에 저장된 구독·리소스 그룹·리전·계정·프로젝트 이름을 재사용하므로 사용자 지정 설치도 bare rerun이 안전합니다.

```bash
bash infra/setup_azure.sh
# 리전/이름 변경: LOCATION=swedencentral ACCOUNT_NAME=my-foundry bash infra/setup_azure.sh
```

생성 항목:
| 리소스 | 설명 |
| --- | --- |
| 리소스 그룹 | `rg-trade-content-understanding` (기본값) |
| Foundry(AIServices) 계정 | `kind=AIServices` + `allowProjectManagement=true` 인 **Microsoft Foundry 리소스**. custom subdomain 포함, 엔드포인트 `https://<name>.services.ai.azure.com/`, 로컬 키 인증 비활성화 |
| Foundry 프로젝트 | `<name>-project` 생성을 시도(포털 노출용). 프로젝트 생성 실패나 비활성화는 Content Understanding API 사용을 막지 않음 |
| 모델 배포 | `gpt-5.2`, `gpt-4.1-mini`, `text-embedding-3-large` |
| 역할 | 본인에게 `Cognitive Services Content Understanding Owner` |

성공하면 마지막에 `완료!  엔드포인트: https://....services.ai.azure.com/` 가 출력되고 프로젝트 루트에 `.env` 가 생성됩니다.

> `gpt-4.1-mini`는 `prebuilt-analyzer-completion-mini` 별칭 매핑에 사용됩니다.
> `gpt-4.1-mini` `2025-04-14`는 현재 **Deprecated** 상태이며 **2026-10-14**에,
> 기본 완성 모델 `gpt-5.2` `2025-12-11`은 **2026-12-12**에 사용 중지됩니다.
> 계속 운영할 경우 각 날짜 전에
> [지원 모델 문서](https://learn.microsoft.com/azure/ai-services/content-understanding/service-limits#supported-generative-models)와
> [모델 수명주기](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirement-schedule)를 확인해
> 배포, `.env`, 기본 모델 매핑과 분석기 모델 설정을 갱신하세요.

> **이미 Foundry 리소스가 있는 경우**(이 단계를 건너뛰려면): `.env.example` 을 `.env` 로 복사한 뒤
> `CONTENTUNDERSTANDING_ENDPOINT` 를 본인 리소스 엔드포인트로 채우세요. 모델 3종(`gpt-5.2`,
> `gpt-4.1-mini`, `text-embedding-3-large`)의 **배포 이름**도 `.env`에 입력하고, 본인에게
> `Cognitive Services Content Understanding Owner` 역할이 있는지 확인하세요.

### 2) 파이썬 환경

```bash
# macOS/Linux
python3 -m venv .venv && source .venv/bin/activate
# Windows Git Bash에서는 대신:
# python -m venv .venv && source .venv/Scripts/activate
pip install -r requirements.txt
```

### 3) 모델 매핑(1회)

```bash
python -m src.setup_defaults
```
> 새 모델 배포 또는 역할 전파가 늦으면 최대 약 2분간 자동 재시도합니다.
> 이전 버전에서 만든 분석기의 모델이 현재 `gpt-5.2` 설정과 다르면 추출 전에 오류와 재생성 명령을 표시합니다.
> 작업지시서는 `python -m src.create_analyzer --recreate`, TechPack은 기존 분석 명령에
> `--recreate-analyzer`를 한 번 추가해 갱신하세요.

### 4) 작업지시서 분석

```bash
python -m src.extract_work_order 작업지시서.pdf
```
> **첫 실행 시** 커스텀 분석기(`trade_work_order`)가 자동으로 생성됩니다(수십 초~1분 소요).
> 이후 실행은 기존 분석기를 재사용합니다. 결과는 `output/작업지시서.json`(정제본)과
> `output/작업지시서.raw.json`(원본)에 저장됩니다.

> **샘플로 바로 테스트**해 보려면(실제 작업지시서가 없을 때):
> ```bash
> python -m src.extract_work_order sample_data/sample_work_order.pdf
> ```
> `sample_data/sample_work_order.pdf` 는 저장소에 포함되어 있습니다. PDF를 다시 만들 때만
> `pip install -r requirements-dev.txt && python sample_data/make_sample_work_order.py` 를 실행하세요.
> 재생성 환경에는 WeasyPrint가 요구하는 OS 라이브러리와 한글 글꼴이 필요할 수 있습니다.

옵션:
```bash
# 출력 경로 지정 + 값에 신뢰도 포함 + 분석기 재생성
python -m src.extract_work_order 작업지시서.pdf --out output/result.json --with-confidence --recreate-analyzer
```
| 옵션 | 설명 |
| --- | --- |
| `--out <경로>` | 정제 JSON 출력 경로(기본 `output/<파일명>.json`) |
| `--with-confidence` | 신뢰도가 반환된 각 스칼라 값에 confidence 점수 포함 |
| `--recreate-analyzer` | 기존 분석기를 새 스키마/모델로 교체(스키마 변경 시) |
| `--no-ensure` | 분석기 존재 확인/자동 생성을 건너뜀(이미 생성된 경우에만 사용) |
| `--no-raw` | 원본(raw) JSON 파일을 저장하지 않음 |

분석기만 따로 만들거나 갱신하려면:
```bash
python -m src.create_analyzer            # 없으면 생성
python -m src.create_analyzer --recreate # 스키마 변경 후 안전하게 교체
```

### 5) TechPack BOM → 고객 양식 Excel (선택)

의류 TechPack의 `BILL OF MATERIALS` 표를 소재 × 컬러웨이 행으로 언피벗해 12개 컬럼 Excel로 저장합니다.

```bash
python -m src.extract_techpack /경로/TechPack.pdf
```

출력:

| 파일 | 내용 |
| --- | --- |
| `output/TechPack.xlsx` | 고객 양식 Excel (`Style`, `COLORWAY`, `Section`, `WEB# / ID#`, `DESCRIPTION`, `QUALITY DETAILS`, `SUPPLIER`, `ARTICLE#`, `ITEM COLOR`, `UOM`, `Item Price`, `COMPONENT`) |
| `output/TechPack.json` | 정제된 TechPack 구조화 필드 |
| `output/TechPack.raw.json` | Content Understanding 원본 응답 |

```bash
# 출력 베이스 경로 지정 + 스키마 변경 후 분석기 재생성
python -m src.extract_techpack /경로/TechPack.pdf --out output/customer_bom --recreate-analyzer
```

## 전체 순서 요약 (복붙용)

처음부터 끝까지 한 번에 따라 할 수 있는 명령 모음입니다(macOS/Linux 기준, Windows 는 Git Bash).

```bash
# 0) 로그인 & 코드
az login
az account set --subscription "<구독 ID 또는 이름>"
git clone https://github.com/junwoojeong100/azure-ai-content-understanding-labs.git && cd azure-ai-content-understanding-labs

# 1) Azure 리소스 생성 (.env 자동 생성)
bash infra/setup_azure.sh

# 2) 파이썬 환경(macOS/Linux)
python3 -m venv .venv && source .venv/bin/activate
# Windows Git Bash에서는 위 줄 대신:
# python -m venv .venv && source .venv/Scripts/activate
pip install -r requirements.txt

# 3) 모델 매핑(1회) — 새 모델/역할 전파 지연은 자동 재시도
python -m src.setup_defaults

# 4-a) 저장소에 포함된 샘플 PDF 로 동작 확인
python -m src.extract_work_order sample_data/sample_work_order.pdf

# 4-b) 실제 작업지시서 분석
python -m src.extract_work_order /경로/작업지시서.pdf
# 결과: output/작업지시서.json (정제본) + output/작업지시서.raw.json (원본)

# 5) (선택) TechPack BOM → Excel
python -m src.extract_techpack /경로/TechPack.pdf
# 결과: output/TechPack.xlsx + output/TechPack.json + output/TechPack.raw.json
```

## 출력 예시 (`output/작업지시서.json`)

```json
{
  "sourceFile": "작업지시서.pdf",
  "analyzerId": "trade_work_order",
  "fields": {
    "documentTitle": "작업지시서",
    "workOrderNumber": "WO-2026-0612",
    "issueDate": "2026-06-12",
    "customer": { "name": "ABC Imports LLC", "contactPerson": "John Carter", "phone": "+1-562-555-0142" },
    "supplier": { "name": "대성정밀공업(주)", "contactPerson": "김영호" },
    "incoterms": "FOB",
    "currency": "USD",
    "lineItems": [
      { "lineNo": 1, "itemCode": "DS-BR-6204", "itemName": "볼 베어링", "quantity": 2000, "unit": "EA", "unitPrice": 1.85, "amount": 3700 }
    ],
    "totals": { "totalQuantity": 4800, "totalAmount": 16230 }
  },
  "markdown": "## 작업지시서 ...",
  "tables": [
    {
      "rowCount": 3,
      "columnCount": 6,
      "cells": [
        { "kind": "rowHeader", "rowIndex": 0, "columnIndex": 0, "content": "작업지시서 번호" },
        { "kind": "content", "rowIndex": 0, "columnIndex": 1, "content": "WO-2026-0612" }
      ]
    }
  ]
}
```

> 위 예시는 핵심 필드와 일부 표 셀만 남긴 유효한 JSON입니다.

## 프로젝트 구조

```
.
├── docs/
│   └── feedback-loop-guide.md # 여러 형식·사용자 피드백 반영 가이드
├── infra/
│   ├── setup_azure.sh       # Azure 리소스 생성 + .env 작성
│   └── teardown_azure.sh    # 리소스 정리(과금 중단)
├── src/
│   ├── config.py            # .env 설정 로드/인증
│   ├── schema.py            # ① 작업지시서 필드 스키마(무엇을 뽑을지)
│   ├── techpack_schema.py   # TechPack BOM 필드 스키마
│   ├── retry.py             # 모델 배포/RBAC 전파 지연 제한 재시도
│   ├── setup_defaults.py    # 모델 매핑(1회)
│   ├── create_analyzer.py   # 커스텀 분석기 생성/갱신
│   ├── extract_work_order.py# 작업지시서 PDF → JSON
│   └── extract_techpack.py  # TechPack PDF → JSON + Excel
├── sample_data/
│   ├── sample_work_order.pdf      # 바로 실행 가능한 샘플
│   └── make_sample_work_order.py  # 샘플 PDF 재생성기
├── tests/
│   └── test_processing.py   # JSON 평탄화·TechPack 언피벗·Excel 회귀 테스트
├── requirements.txt         # 런타임 의존성
├── requirements-dev.txt     # 샘플 생성용(weasyprint)
├── .env.example
└── README.md
```

## 여러 문서 형식과 사용자 피드백 처리

**문서 양식 수만큼 앱을 만들 필요는 없습니다.**

| 달라진 부분 | 보통 필요한 변경 |
| --- | --- |
| 배치나 항목 이름만 다름 | 기존 분석기와 스키마를 먼저 재사용 |
| 추출할 데이터 구조가 완전히 다름 | 문서군별 분석기 추가 |
| 목표 Excel의 컬럼·행 규칙만 다름 | Excel 출력 변환기만 추가 |
| 문서 종류를 자동으로 골라야 함 | 분류기/라우터 추가 |

사용자가 제공한 목표 Excel은 자동 학습 파일이 아니라 **정답 예시**입니다. 다음 순서로 피드백을 반영합니다.

1. 같은 PDF로 RAW JSON과 정제 JSON을 만들고, Excel 변환이 구현된 경우 현재 Excel도 만듭니다.
2. JSON부터 확인해 추출 문제인지 Excel 변환 문제인지 구분합니다.
3. 스키마 또는 Python 변환 코드 중 한쪽만 수정합니다.
4. 같은 문제가 다시 생기지 않도록 테스트를 추가합니다.
5. 목표 Excel과 다시 비교하고 사용자에게 확인받습니다.

용어 설명, 여러 양식의 분석기 분리 기준, 문제 위치를 찾는 네 가지 질문, GitHub Copilot CLI용 프롬프트,
실제 명령과 완료 체크리스트는 다음 문서에서 단계별로 설명합니다.

> **[초보자를 위한 사용자 피드백 루프 가이드](docs/feedback-loop-guide.md)**

## 추출 항목을 간단히 바꾸기

문서에는 값이 있지만 정제 JSON에서 빠졌을 때 스키마를 수정합니다.

- 작업지시서: `src/schema.py`
- TechPack: `src/techpack_schema.py`

필드 `description`에 실제 문서의 별칭(예: `납기일/완료예정일/Delivery Date`)을 추가하면 같은 의미의
다른 표기를 찾는 데 도움이 됩니다.

```bash
# 작업지시서 스키마를 바꾼 경우
python -m src.create_analyzer --recreate

# TechPack 스키마를 바꾼 경우
python -m src.extract_techpack TechPack.pdf --recreate-analyzer

# 변경 후 기존 동작 확인
python -m unittest discover -s tests -v
```

정제 JSON은 맞고 Excel만 틀렸다면 스키마가 아니라 출력 변환 코드를 수정해야 합니다. 자세한 판단 방법은
[피드백 루프 가이드](docs/feedback-loop-guide.md)를 참고하세요.

## 비용/정리

리소스는 사용량 기반 과금됩니다. 사용 후 정리:
```bash
bash infra/teardown_azure.sh    # 현재 구독을 확인한 뒤 리소스 그룹 이름을 입력해 삭제
```
스크립트가 `.env`에 저장한 구독 ID와 리소스 그룹을 표시하므로 확인한 뒤, 삭제 확인란에 리소스 그룹 이름을 그대로 입력해야 합니다.
Foundry 리소스는 삭제 후 최대 48시간 soft-delete 상태로 남아 같은 이름을 새로 만들 수 없습니다.
이 가이드의 `setup_azure.sh`는 같은 리소스 그룹·리전·계정 이름으로 다시 실행하면 soft-delete 리소스를 자동 복구합니다.
완전 영구 삭제(purge)가 필요하면 [Microsoft의 복구/제거 안내](https://learn.microsoft.com/azure/ai-services/recover-purge-resources)를 따르세요.

## 문제 해결 (Troubleshooting)

| 증상 | 원인 / 해결 |
| --- | --- |
| `az login` 미로그인 / 구독 여러 개 | `setup_azure.sh` 가 감지해 안내합니다. `az login` 후 `az account set --subscription "<구독 ID 또는 이름>"` 로 대상 구독을 선택하세요. |
| 정리할 리소스 그룹이 없다고 표시됨 | `.env`의 `AZURE_SUBSCRIPTION_ID`와 `AZURE_RESOURCE_GROUP`이 실제 생성 대상과 같은지 확인하세요. 다른 대상을 정리하려면 두 값을 수정하거나 환경 변수로 재정의하세요. |
| Azure CLI 에 `account project`/`allow-project-management`가 없음 | Azure CLI가 오래된 버전입니다. `az upgrade` 또는 https://aka.ms/azcli 로 업데이트하세요. |
| 파이썬 실행 시 인증 오류(`DefaultAzureCredential`/401/403) | ① `az login` 세션이 살아있는지, ② 본인에게 리소스의 `Cognitive Services Content Understanding Owner` 역할이 있는지 확인하세요. 스크립트는 키 인증을 비활성화하므로 Entra ID 인증이 필요합니다. |
| 역할 자동 부여 실패(Azure RBAC Contributor만 보유) | 역할 부여에는 Azure RBAC **Owner/User Access Administrator/Role Based Access Control Administrator** 가 필요합니다. 관리자에게 `Cognitive Services Content Understanding Owner` 역할을 요청한 뒤 3) 단계를 진행하세요. |
| Windows 에서 `infra/*.sh` 실행 안 됨 | bash 스크립트입니다. **WSL** 또는 **Git Bash** 에서 `bash infra/setup_azure.sh` 로 실행하세요. |
| `InsufficientQuota` 또는 모델 배포 실패 | 스크립트가 `GlobalStandard` → `Standard` → `DataZoneStandard` 순으로 사용 가능한 SKU를 시도합니다. 모두 실패하면 `az cognitiveservices usage list -l <region> -o table`로 할당량을 확인하고 다른 리전 또는 증설을 사용하세요. |
| `setup_defaults`/분석이 401/403 또는 `DeploymentIdNotFound` | 새 역할·모델 배포 전파 중이면 최대 약 2분간 자동 재시도합니다. 계속 실패하면 역할과 실제 모델 배포 이름을 확인하세요. |
| `Model deployment not found` | `.env`의 `GPT_5_2_DEPLOYMENT`, `GPT_4_1_MINI_DEPLOYMENT`, `TEXT_EMBEDDING_3_LARGE_DEPLOYMENT` 값이 실제 배포 이름과 일치하는지 확인하고 `python -m src.setup_defaults`를 다시 실행하세요. |
| 기존 분석기의 모델 설정이 현재 `.env`와 다름 | 구형 분석기를 안전하게 자동 덮어쓰지 않고 중단한 것입니다. 작업지시서는 `python -m src.create_analyzer --recreate`, TechPack은 분석 명령에 `--recreate-analyzer`를 추가해 한 번 재생성하세요. |
| 삭제 후 같은 계정 이름을 다시 사용할 수 없음 | Foundry soft-delete 때문입니다. 같은 설정으로 `setup_azure.sh`를 실행하면 자동 복구합니다. 영구 purge 후 새로 만들려면 위 비용/정리 절의 Microsoft 안내를 따르세요. |
| 분석기 ID 오류 | `WORK_ORDER_ANALYZER_ID`/`TECHPACK_ANALYZER_ID`는 서로 달라야 하며 `[A-Za-z0-9._]{1,64}` 형식만 허용합니다. |
| 추출 정확도가 낮음 | `src/schema.py` 의 필드 `description` 에 양식에 맞는 한국어 별칭을 추가하고 `python -m src.create_analyzer --recreate` 로 재생성하세요. |

## 참고
- SDK: [`azure-ai-contentunderstanding`](https://pypi.org/project/azure-ai-contentunderstanding/) (API `2025-11-01`)
- 문서: https://learn.microsoft.com/azure/ai-services/content-understanding/
- 리전: https://learn.microsoft.com/azure/ai-services/content-understanding/language-region-support
- 모델: https://learn.microsoft.com/azure/ai-services/content-understanding/concepts/models-deployments

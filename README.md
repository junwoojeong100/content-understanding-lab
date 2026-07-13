# Azure AI Content Understanding 실습: 작업지시서 JSON + TechPack BOM Excel

Azure AI Content Understanding으로 다음 두 문서 자동화 흐름을 실습하는 Python 프로젝트입니다.

- **작업지시서(Work Order)** PDF → 구조화 JSON + 서비스 원본 JSON
- **의류 TechPack BOM** PDF → 구조화 JSON + 고객 양식 Excel(12개 컬럼)

관련 Foundry 리소스, 모델 배포, Entra ID 역할, `.env`를 준비하는 Azure CLI 스크립트도 포함합니다.

## 동작 방식

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

## 정제된 구조화 데이터는 어떻게 만들어지나

`output/<name>.json` 의 `fields` 는 서비스가 그대로 준 것이 아니라 **두 단계의 추가 작업**으로 만들어집니다.

### ① 필드 스키마 정의 — `src/schema.py` (무엇을 뽑을지)

`prebuilt-documentSearch` 만 쓰면 마크다운·표(텍스트)만 나오고 **업무 필드는 나오지 않습니다.**
커스텀 분석기에 작업지시서 필드 스키마(`build_work_order_schema()`)를 넣어 분석기를 만들면,
서비스 측 LLM(gpt-5.2)이 RAW 응답 안에 `fields`(`workOrderNumber`, `customer.name`,
`lineItems[]` …)를 생성합니다.
- 배열(품목 내역)은 `item_definition`, 객체(거래처 등)는 `properties`, 고정값(통화·인도조건)은 enum(`classify`)
- 필드 `description` 의 한국어 별칭이 추출 정확도를 높입니다.

### ② 평탄화 후처리 — `src/extract_work_order.py` 의 `_simplify_field()` (보기 좋게 다듬기)

RAW 의 각 필드는 `type / value* / spans / confidence / source` 가 붙은 장황한 객체입니다.
이를 재귀적으로 **값만** 남깁니다.

```jsonc
// RAW (output/<name>.raw.json)
"workOrderNumber": {
  "type": "string", "valueString": "WO-2026-0612",
  "spans": [{ "offset": 107, "length": 12 }],
  "confidence": 0.72, "source": "D(1,2.07,1.33,...)"
}
```
```jsonc
// 정제본 (output/<name>.json)
"workOrderNumber": "WO-2026-0612"
```

- 스칼라: `type` 에 맞는 `value*` 키(`valueString`/`valueNumber`/`valueDate`…)만 추출
- object → `valueObject`, array(품목) → `valueArray` 안으로 재귀
- `--with-confidence` 옵션을 주면 `{ "value": ..., "confidence": ... }` 형태로 신뢰도 보존

> **두 출력 파일의 관계**: `*.json` = RAW 안 `fields` 의 정제본 · `*.raw.json` = 서비스 원본 전체(spans·confidence·source·layout 포함, **정보 손실 없음**).
> 즉 ①은 "무엇을 뽑을지"를 서비스에 지시(추출 품질 결정), ②는 "뽑힌 결과를 보기 좋게 다듬는" 로컬 변환입니다.

## 사전 요구사항

- **Azure 구독** 과 권한:
  - 리소스/모델 생성: **Contributor** 이상
  - 역할 자동 부여: **Owner**, **User Access Administrator** 또는
    **Role Based Access Control Administrator**.
  - 스크립트는 분석기 생성·삭제·분석에 필요한 최소 범위의
    `Cognitive Services Content Understanding Owner` 역할을 본인에게 부여합니다.
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
| Foundry 프로젝트 | `<name>-project` (Foundry 포털 ai.azure.com 노출용) |
| 모델 배포 | `gpt-5.2`, `gpt-4.1-mini`, `text-embedding-3-large` |
| 역할 | 본인에게 `Cognitive Services Content Understanding Owner` |

성공하면 마지막에 `완료!  엔드포인트: https://....services.ai.azure.com/` 가 출력되고 프로젝트 루트에 `.env` 가 생성됩니다.

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
| `--with-confidence` | 각 값에 신뢰도(confidence) 점수 포함 |
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

## 사용자 샘플과 피드백으로 결과 앱 완성하기

사용자가 **원본 작업지시서/PDF**와 **원하는 최종 Excel**을 제공하면, 최종 Excel은 학습 파일이 아니라
앱이 맞춰야 할 **골든 출력(golden output)** 으로 사용합니다. 사용자의 반복 피드백은 다음 두 위치 중
알맞은 곳에 코드로 반영하고, 같은 문제가 다시 생기지 않도록 회귀 테스트로 고정합니다.

```text
원본 문서
   │
   ▼
Content Understanding 분석기 ── schema.py / techpack_schema.py
   │                           "무엇을 추출할지"
   ▼
RAW JSON → 정제 JSON
              │
              ▼
고객별 결정적 변환 로직 ─────── unpivot_rows(), _clean_*() 등
              │                 "어떻게 행·열·값을 구성할지"
              ▼
목표 Excel ── 사용자 피드백 → 규칙 수정 → 회귀 테스트 → 재실행
```

> Content Understanding 공식 가이드도 샘플 업로드 → 스키마 정의 → 분석 테스트 → 스키마 반복 개선을
> 권장합니다. 이 프로젝트는 그 과정에 **고객별 출력 변환**과 **로컬 회귀 테스트**를 추가합니다.
> [공식 custom analyzer 개선 가이드](https://learn.microsoft.com/azure/ai-services/content-understanding/how-to/customize-analyzer-content-understanding-studio)

### 1) 먼저 입력·정답·판정 규칙을 확보

최소한 다음 자료를 한 세트로 준비합니다.

- 대표 원본 문서 여러 개: 정상 양식뿐 아니라 페이지 수, 표 구조, 빈 값이 다른 사례도 포함
- 각 원본에 대응하는 목표 Excel: 시트명, 컬럼명/순서, 행 단위, 셀 값이 확정된 파일
- 업무 규칙: 값 분리/결합, 빈 값, 기본값, 단위, 반올림, 중복 처리, 컬러웨이 전개 방식
- 피드백의 적용 범위: 특정 문서만의 예외인지 앞으로 모든 문서에 적용할 일반 규칙인지

실제 고객 문서와 Excel에는 민감정보가 있을 수 있으므로 저장소에는 원본을 커밋하지 말고,
테스트에는 문제를 재현하는 최소한의 익명화된 JSON과 기대값만 남깁니다.

### 2) 기준 결과를 만들고 모든 단계의 결과를 함께 비교

```bash
# 작업지시서: 정제 JSON에서도 confidence를 함께 확인
python -m src.extract_work_order /경로/작업지시서.pdf --with-confidence

# TechPack: RAW JSON, 정제 JSON, 현재 Excel을 한 번에 생성
python -m src.extract_techpack /경로/TechPack.pdf --out output/baseline
```

원본 문서, `*.raw.json`, 정제된 `*.json`, 목표 `*.xlsx`를 나란히 비교합니다. Excel만 보고 바로
후처리 코드를 고치면 추출 문제와 변환 문제를 혼동하기 쉬우므로, 먼저 값이 어느 단계까지 올바른지 확인합니다.

### 3) 피드백을 수정 계층별로 분류

| 비교 결과 | 수정 위치 | 분석기 재생성 |
| --- | --- | --- |
| 문서에는 값이 있지만 RAW/정제 JSON의 `fields`가 누락되거나 잘못됨 | `src/schema.py` 또는 `src/techpack_schema.py`의 필드 타입·구조·`description` | 필요 |
| RAW `fields`는 맞지만 정제 JSON 값이 잘못됨 | `src/extract_work_order.py`의 평탄화 또는 공통 정규화 로직 | 불필요 |
| 정제 JSON은 맞지만 Excel의 행 수, 컬럼, 값 분리/결합이 다름 | `unpivot_rows()` 같은 고객별 결정적 변환 함수 | 불필요 |
| 셀 값은 맞지만 시트명, 헤더, 너비, 표시 형식이 다름 | `write_excel()` 같은 Excel 작성 함수 | 불필요 |
| 값의 출처나 누락 원인을 알 수 없음 | `*.raw.json`의 `markdown`, `tables`, `source`, `confidence`부터 확인 | 진단 후 결정 |

스키마는 문서의 **업무 의미를 가진 필드**를 안정적으로 추출하는 데 집중하고, 고객 Excel의 컬럼 순서나
행 복제 같은 표현 규칙은 Python 후처리에서 구현합니다. 모든 출력 규칙을 분석기 프롬프트에 넣는 것보다
이 방식이 결정적이고 테스트하기 쉽습니다.

### 4) 사용자 피드백 한 건을 규칙 한 개와 테스트 한 개로 변환

피드백을 “결과가 이상함”으로 기록하지 말고 다음처럼 검증 가능한 규칙으로 바꿉니다.

| 사용자 피드백 | 코드 규칙의 예 | 회귀 테스트의 예 |
| --- | --- | --- |
| “모든 소재가 각 컬러웨이별 한 행이어야 함” | `unpivot_rows()`에서 소재 × 컬러웨이 행 생성 | 소재 2개 × 컬러웨이 2개 = 4행 |
| “빈 COMPONENT는 위 회색 그룹명을 따라야 함” | `_resolve_components()`에서 직전 그룹명 승계 | 헤더 전용 행 다음 소재의 COMPONENT 확인 |
| “가격에서 SP24/LIST는 빼야 함” | `_clean_price()`에서 통화·금액·단위만 보존 | `$3.200 yd SP24` → `$3.200 yd` |
| “Excel 컬럼 순서는 항상 동일해야 함” | `EXCEL_COLUMNS`를 단일 기준으로 사용 | 생성된 첫 행 헤더 전체 비교 |
| “납기일이 다른 이름으로 적힌 문서에서 누락됨” | 스키마 `description`에 실제 별칭 추가 | 분석기 재생성 후 해당 샘플 재분석 |

피드백 기록에는 가능하면 `입력 문서/페이지`, `현재 값`, `기대값`, `일반 규칙`, `예외`,
`수정 계층`, `추가한 테스트`를 남깁니다. 이렇게 해야 다음 피드백이 이전 수정과 충돌하는지 판단할 수 있습니다.

### 5) 한 계층씩 수정하고 같은 샘플로 반복

1. 추출 문제일 때만 스키마를 수정합니다.
2. 스키마를 바꿨다면 분석기를 재생성하고 같은 문서를 다시 분석합니다.
3. 정제 JSON이 맞아진 뒤 고객별 변환과 Excel 표시를 수정합니다.
4. 피드백을 재현하는 최소 회귀 테스트를 `tests/test_processing.py`에 추가합니다.
5. 전체 회귀 테스트와 목표 Excel 비교를 통과한 결과를 사용자에게 다시 확인받습니다.
6. 새 피드백을 다음 판정 규칙으로 추가하고 같은 순서를 반복합니다.

```bash
# 작업지시서 스키마를 바꾼 경우
python -m src.create_analyzer --recreate
python -m src.extract_work_order /경로/작업지시서.pdf

# TechPack 스키마를 바꾼 경우
python -m src.extract_techpack /경로/TechPack.pdf --recreate-analyzer

# Python 후처리만 바꾼 경우 분석기 재생성 없이 테스트
python -m unittest discover -s tests -v
```

`--recreate-analyzer`는 스키마나 분석기 모델을 변경했을 때만 필요합니다. 행/열 변환, 값 정리,
Excel 서식 같은 로컬 Python 코드만 수정했다면 분석기를 재생성하지 말고 익명화된 JSON 테스트 데이터로
빠르게 반복한 뒤, 최종 확인 시 원본 문서를 다시 분석합니다.

### 6) 새 고객 Excel 형식 추가 방향

현재 `extract_techpack.py`가 이 패턴의 예입니다. 다른 작업지시서용 Excel을 추가할 때도 다음처럼 계층을
분리합니다.

1. `schema.py`에는 여러 고객 양식에서 재사용할 수 있는 업무 필드를 정의합니다.
2. 정제 JSON을 받아 목표 행을 반환하는 순수 함수(예: `build_customer_rows(fields)`)를 만듭니다.
3. 행 데이터와 Excel 서식을 분리해 `write_customer_excel(rows, path)`에서 파일을 생성합니다.
4. 익명화된 입력 필드와 기대 행/헤더를 `tests/test_processing.py`에 추가합니다.

특정 샘플의 문자열이나 행 번호를 하드코딩하지 말고, 사용자에게 확인받은 일반 규칙을 구현해야 다른 문서에도
동일하게 적용됩니다. 대표 샘플 전체에서 필드 값, 행 수, 컬럼 순서, 핵심 셀, 빈 값/예외가 목표 Excel과
일치하고 모든 피드백이 테스트로 남았을 때 해당 고객용 앱이 완성된 것으로 판단합니다.

## 스키마 커스터마이징

작업지시서 양식에 맞춰 `src/schema.py` 의 `build_work_order_schema()` 에서 필드를 추가/수정한 뒤
`python -m src.create_analyzer --recreate` 로 분석기를 다시 만들면 됩니다.
필드 `description` 에 한국어 별칭(예: "납기일/완료예정일/Due Date")을 풍부하게 적을수록 추출 정확도가 올라갑니다.

TechPack은 `src/techpack_schema.py`를 수정한 뒤
`python -m src.extract_techpack TechPack.pdf --recreate-analyzer`로 재생성합니다.

로컬 후처리 회귀 테스트:

```bash
python -m unittest discover -s tests -v
```

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
| 파이썬 실행 시 인증 오류(`DefaultAzureCredential`/401) | ① `az login` 세션이 살아있는지, ② 본인에게 리소스의 `Cognitive Services Content Understanding Owner` 역할이 있는지 확인하세요. 스크립트는 키 인증을 비활성화하므로 Entra ID 인증이 필요합니다. |
| 역할 자동 부여 실패(Contributor만 보유) | 역할 부여에는 **Owner/User Access Administrator/Role Based Access Control Administrator** 가 필요합니다. 관리자에게 Content Understanding Owner 역할을 요청한 뒤 3) 단계를 진행하세요. |
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

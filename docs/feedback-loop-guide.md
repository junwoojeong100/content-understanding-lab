# 사용자 피드백으로 문서 처리 앱을 완성하는 방법

이 문서는 처음 문서 자동화 프로젝트를 만드는 분을 위한 안내서입니다.

[← README로 돌아가기](../README.md)

다음 질문에 답하는 것이 목표입니다.

- 작업지시서 양식이 여러 개면 앱도 여러 개 만들어야 하나?
- 추출 결과가 틀렸을 때 어느 파일을 고쳐야 하나?
- 사용자의 피드백을 어떻게 코드와 테스트로 남기나?
- 언제 분석기를 새로 만들고, 언제 Excel 변환기만 추가하나?
- GitHub Copilot CLI를 사용하면 어떤 작업을 맡길 수 있나?

처음에는 모든 내용을 외울 필요가 없습니다. **1~4절로 전체 구조를 이해한 뒤**, 실제 결과가 틀렸을 때
7절의 네 가지 질문을 따라가면 됩니다. GitHub Copilot CLI를 사용한다면 4절 다음의 Copilot 사용법도
함께 읽어보세요.

## 한 줄로 먼저 이해하기

대부분은 **앱 하나**에서 여러 문서 형식과 여러 Excel 형식을 처리할 수 있습니다.

```text
원본 PDF
   ↓
앱 또는 CLI
   ↓
알맞은 분석기 선택
   ↓
정제 JSON
   ↓
고객별 Excel 변환
   ↓
목표 Excel
```

문서의 **업무 내용이 같고 배치만 다르면 분석기를 재사용**합니다. 추출해야 할 데이터 구조가
완전히 다를 때만 분석기를 추가합니다. 최종 Excel의 컬럼이나 행 규칙만 다르면 분석기는 그대로 두고
Excel 변환기만 추가합니다.

## 1. 먼저 용어를 쉽게 구분하기

| 용어 | 쉬운 비유 | 역할 | 현재 프로젝트의 예 |
| --- | --- | --- | --- |
| 앱 또는 CLI | 문서를 받는 접수 창구 | 파일을 받고 전체 순서를 실행 | `python -m src.extract_work_order ...` |
| 분석기(analyzer) | 문서를 읽는 담당자 | PDF에서 필요한 값을 찾음 | `trade_work_order`, `techpack_bom` |
| 스키마(schema) | 담당자의 확인 항목 목록 | 어떤 값을 어떤 이름으로 뽑을지 정의 | `src/schema.py`, `src/techpack_schema.py` |
| RAW JSON | 서비스가 준 원본 답안 | 위치, 신뢰도, 표 등 상세 결과 보존 | `output/*.raw.json` |
| 정제 JSON | 사람이 보기 쉽게 정리한 답안 | 복잡한 필드 객체에서 실제 값만 남김 | `output/*.json` |
| 출력 변환기 | 고객 양식에 맞추는 Excel 담당자 | JSON을 원하는 행·열로 변경 | `unpivot_rows()`, `write_excel()` |
| 분류기/라우터 | 문서를 담당자에게 보내는 안내원 | 문서 종류를 자동 판별 | 현재 코드에는 아직 없음 |
| 회귀 테스트 | 고친 문제가 다시 생기는지 확인하는 검사 | 입력과 기대 결과를 자동 비교 | `tests/test_processing.py` |

가장 중요한 구분은 다음 두 가지입니다.

- **분석기와 스키마**: 문서에서 무엇을 추출할지 결정합니다.
- **출력 변환기**: 추출한 값을 어떤 Excel 행과 컬럼에 넣을지 결정합니다.

예를 들어 같은 작업번호도 RAW JSON에는 상세 정보와 함께 들어오지만, 정제 JSON에는 실제 값만 남습니다.

```jsonc
// RAW JSON 안의 fields
{
  "workOrderNumber": {
    "type": "string",
    "valueString": "WO-2026-0612",
    "confidence": 0.92
  }
}

// 정제 JSON
{
  "workOrderNumber": "WO-2026-0612"
}
```

## 2. 문서 형식마다 앱이 필요한가?

아닙니다. “형식이 다르다”는 말을 세 가지로 나누어 생각해야 합니다.

| 달라진 부분 | 예시 | 보통 필요한 변경 |
| --- | --- | --- |
| 화면 배치만 다름 | 납기일이 문서 위쪽 또는 아래쪽에 있음 | 기존 분석기 재사용 |
| 같은 값의 이름만 다름 | `납기일`, `완료예정일`, `Delivery Date` | 스키마 설명에 별칭 추가 |
| 추출할 데이터 구조가 다름 | 일반 작업지시서와 TechPack BOM | 문서군별 분석기 추가 |
| 목표 Excel만 다름 | 고객 A는 12컬럼, 고객 B는 9컬럼 | 출력 변환기 추가 |
| 문서 종류를 자동으로 골라야 함 | 하나의 업로드 화면으로 여러 종류 접수 | 분류기/라우터 추가 |
| 보안과 운영 환경이 완전히 다름 | 고객별 망 분리, 별도 운영 조직 | 별도 앱 또는 배포 검토 |

예를 들어 화면 디자인은 10개지만 업무상 문서 종류가 2개이고 목표 Excel이 3개라면 다음 구조가
될 수 있습니다.

```text
앱 1개
분석기 2개
Excel 출력 변환기 3개
```

처음부터 양식마다 분석기를 만들지 마세요. 같은 업무 필드를 가진 문서는 먼저 하나의 분석기로 시험합니다.
대표 샘플에서 계속 표를 혼동하거나, 같은 필드 이름이 서로 다른 뜻으로 사용될 때 분석기를 나눕니다.

## 3. 현재 저장소는 어떻게 동작하나?

현재 저장소는 웹 앱이 아니라 Python 실습 프로젝트입니다. 사용자가 명령을 선택해 문서 종류를 직접
알려줍니다.

```text
작업지시서
python -m src.extract_work_order 작업지시서.pdf
  → trade_work_order 분석기
  → output/작업지시서.raw.json
  → output/작업지시서.json

TechPack
python -m src.extract_techpack TechPack.pdf
  → techpack_bom 분석기
  → output/TechPack.raw.json
  → output/TechPack.json
  → output/TechPack.xlsx
```

분석기는 두 개지만 코드베이스는 하나입니다. 하나의 업로드 API에서 문서 종류까지 자동으로 판단하려면
나중에 Content Understanding 분류기와 라우팅을 추가할 수 있습니다. 현재 코드에는 자동 분류 기능이
구현되어 있지 않습니다.

## 4. 목표 Excel은 학습 파일이 아니라 정답 예시

이 저장소에서는 사용자가 제공한 최종 Excel을 Content Understanding에 그대로 학습시키지 않습니다.
개발자나 Copilot이 현재 결과와 비교하는 **목표 결과**로 사용합니다. Content Understanding의 선택 기능인
in-context learning은 별도로 준비한 라벨 문서 샘플을 사용하며, 여기서 설명하는 목표 Excel 비교와는 다른 절차입니다.

다음 네 가지를 한 묶음으로 준비합니다.

1. 원본 PDF
2. Content Understanding의 RAW JSON
3. 정제 JSON
4. 사용자가 원하는 목표 Excel

사용자 피드백은 “AI가 알아서 학습한다”기보다 다음 과정으로 앱에 반영됩니다.

```text
사용자 피드백
   ↓
정확한 업무 규칙으로 정리
   ↓
스키마 또는 Python 변환 코드 수정
   ↓
회귀 테스트 추가
   ↓
같은 샘플로 다시 실행
   ↓
사용자 확인
```

## GitHub Copilot CLI를 사용하면 더 간단해지는 부분

GitHub Copilot CLI를 사용하면 파일을 일일이 찾고, 수정 위치를 추측하고, 테스트와 PR 명령을 직접
반복하는 작업을 줄일 수 있습니다. 이 문서에서는 GitHub Copilot CLI를 간단히 **Copilot**이라고
부릅니다.

먼저 Copilot CLI를 설치하고 GitHub에 로그인해야 합니다. 설치 방법은 아래 참고 문서에서 확인할 수 있습니다.
저장소 루트에서 다음처럼 시작합니다.

```bash
cd azure-ai-content-understanding-labs
copilot
```

Copilot이 현재 폴더의 파일을 읽고 수정할 수 있으므로, 신뢰할 수 있는 저장소인지 확인한 뒤 접근을
승인합니다.

가장 간단한 사용 방법은 세 단계입니다.

1. 원본 문서, 목표 Excel, 현재 결과와 원하는 차이를 알려줍니다.
2. 문제 단계 확인 → 한 계층 수정 → 회귀 테스트 추가 → 테스트 실행을 요청합니다.
3. 결과 Excel과 `/diff`를 확인한 뒤 PR을 만듭니다.

### Copilot이 맡을 수 있는 작업

| 직접 작업할 때 | Copilot을 사용할 때 |
| --- | --- |
| 관련 Python 파일을 직접 찾음 | 저장소를 검색해 관련 스키마·변환·테스트 파일을 찾음 |
| JSON과 Excel을 보며 수정 위치를 추측 | RAW JSON → 정제 JSON → Excel 순서로 문제 단계를 구분 |
| 코드를 직접 수정 | 스키마 또는 출력 변환 코드 중 필요한 부분을 수정 |
| 테스트 사례를 직접 작성 | 사용자 피드백을 재현하는 회귀 테스트를 추가 |
| 테스트 명령을 직접 실행하고 오류를 추적 | 테스트를 실행하고 실패 원인을 찾아 수정 |
| 변경 파일을 하나씩 확인 | `/diff`와 `/review`로 변경 내용을 확인 |
| 브랜치·커밋·PR 작업을 직접 수행 | `/pr`을 사용하거나 `/delegate --base main`으로 PR 작업 위임 |

Copilot을 사용하면 다음 반복 과정이 하나의 대화로 이어집니다.

```text
원본 PDF와 목표 Excel 경로 전달
   ↓
Copilot이 현재 코드와 결과 파일 조사
   ↓
추출 문제인지 Excel 변환 문제인지 구분
   ↓
코드 수정 + 회귀 테스트 추가
   ↓
테스트 실행 + 변경 내용 설명
   ↓
사용자 확인 후 PR 생성
```

### 그래도 사용자가 직접 결정해야 하는 것

Copilot이 업무 규칙 자체를 임의로 정하면 안 됩니다. 다음 내용은 사용자가 알려줘야 합니다.

- 어떤 Excel이 올바른 최종 결과인지
- 현재 값과 원하는 값이 정확히 무엇인지
- 피드백이 모든 문서에 적용되는 일반 규칙인지 특정 문서만의 예외인지
- 원본 문서에 없는 값을 기본값으로 채울지, 계산할지, 비워둘지
- 최종 결과를 업무에서 사용해도 되는지

즉 Copilot은 **개발 작업을 빠르게 수행하는 도구**이고, 사용자는 **업무 정답을 알려주는 사람**입니다.

<details>
<summary>복사해서 쓰는 프롬프트와 Copilot CLI 명령 보기</summary>

### 파일을 Copilot에 알려주는 방법

Copilot CLI에서는 `@`로 저장소 파일을 대화에 포함할 수 있습니다. PDF는 지원 모델을 사용할 때
`@`로 첨부할 수도 있습니다.

```text
@docs/feedback-loop-guide.md
@src/schema.py
@src/extract_work_order.py
@src/extract_techpack.py
@tests/test_processing.py
```

원본 PDF나 목표 Excel이 저장소 밖에 있다면 먼저 `/add-dir`로 해당 폴더의 접근을 허용한 뒤 파일 경로를
알려줍니다. PDF는 직접 첨부할 수 있지만, `.xlsx`는 공식 첨부 형식이 아니므로 경로를 알려주고 Python과
`openpyxl`로 내용을 비교하도록 요청합니다. 실제 고객 문서는 저장소에 복사하거나 커밋하지 않습니다.
민감한 파일을 Copilot에 제공하기 전에는 조직의 데이터 보호 정책을 확인하고, 필요하면 익명화된 샘플을 사용합니다.

```text
/add-dir /경로/고객샘플폴더
```

### 처음 요청할 때 사용할 프롬프트

다음 형식을 복사해 실제 경로와 요구사항만 바꿔 사용할 수 있습니다.

```text
다음 가이드를 기준으로 작업해줘: @docs/feedback-loop-guide.md

원본 문서: /경로/작업지시서.pdf
목표 Excel: /경로/원하는결과.xlsx
현재 결과: output/현재결과.json 또는 output/현재결과.xlsx

먼저 다음을 확인해줘.
1. 기존 작업지시서 분석기를 재사용할 수 있는 형식인지
2. 문제가 스키마 추출인지 JSON 후처리인지 Excel 변환인지
3. 목표 Excel에서 일반화해야 할 행·컬럼 규칙이 무엇인지

그다음 한 계층만 수정하고, 피드백을 재현하는 테스트를 추가해줘.
실제 고객 데이터나 특정 행 번호를 하드코딩하지 말고 기존 테스트도 실행해줘.
마지막에는 변경 파일과 결과를 간단히 설명해줘.
```

작업 범위가 크다면 `/plan`을 실행하거나 <kbd>Shift</kbd>+<kbd>Tab</kbd>으로 plan mode를 선택해
계획을 검토한 뒤 구현을 시작할 수 있습니다. 요구사항과 정답이 명확하다면 `/autopilot`을 사용해 조사,
수정, 테스트 과정을 계속 진행하도록 맡길 수도 있습니다.

### 다음 피드백을 줄 때 사용할 프롬프트

첫 요청 이후에는 전체 설명을 반복하지 않고, 변경된 기대값만 구체적으로 알려주면 됩니다.

```text
사용자 피드백:
- 입력 문서/페이지: TechPack.pdf 3페이지
- 현재 결과: Item Price가 "$3.200 yd SP24"
- 원하는 결과: "$3.200 yd"
- 일반 규칙: 모든 가격에서 SP24와 LIST 태그 제거
- 예외: 없음

먼저 RAW JSON과 정제 JSON 중 어디까지 값이 올바른지 확인해줘.
필요한 계층만 수정하고 이 규칙의 회귀 테스트를 추가한 뒤 테스트를 실행해줘.
```

이렇게 피드백을 주면 Copilot이 이전 코드와 테스트를 읽고, 새 규칙이 기존 동작을 깨뜨리는지도 함께
확인할 수 있습니다.

### 변경 내용과 PR 확인

수정이 끝나면 다음 기능을 사용할 수 있습니다.

| 기능 | 사용 시점 |
| --- | --- |
| `/diff` | Copilot이 바꾼 파일과 변경 내용을 확인 |
| `/review` | 변경 코드에서 오류 가능성을 한 번 더 검토 |
| `!python -m unittest discover -s tests -v` | 테스트를 직접 다시 실행 |
| `/pr` | 현재 브랜치의 PR 확인과 작업 |
| `/delegate --base main` | 작업을 GitHub에 위임해 `main` 대상 PR 생성 |

자동 생성된 결과라도 목표 Excel과 일치하는지는 사용자가 마지막으로 확인해야 합니다.

### 반복 규칙을 저장소에 알려주기

매번 같은 원칙을 프롬프트에 적고 싶지 않다면 `.github/copilot-instructions.md`에 저장소 규칙을 적을 수
있습니다. Copilot CLI는 이 파일의 지침을 읽고 이후 작업에 반영합니다.

예를 들면 다음 규칙을 기록할 수 있습니다.

```markdown
- 실제 고객 PDF와 Excel을 저장소에 커밋하지 않는다.
- 같은 업무 의미를 가진 문서 형식은 기존 분석기를 먼저 재사용한다.
- 정제 JSON이 맞으면 스키마를 수정하지 않고 출력 변환기를 수정한다.
- 사용자 피드백 한 건마다 회귀 테스트 한 개를 추가한다.
- 변경 후 `python -m unittest discover -s tests -v`를 실행한다.
```

</details>

## 5. 시작 전에 준비할 자료

가능하면 다음 자료를 받습니다.

- 각 문서군 또는 양식의 대표 PDF 2~3개
- 같은 문서군 안에서도 표 구조, 페이지 수, 빈 값이 다른 PDF
- 각 PDF에 대응하는 목표 Excel
- 컬럼 순서, 행 생성 방법, 기본값, 단위, 반올림 규칙
- 피드백이 모든 문서에 적용되는지 특정 문서만의 예외인지에 대한 설명

실제 고객 문서에는 개인정보나 영업정보가 있을 수 있습니다. 원본 문서를 저장소에 커밋하지 말고,
테스트에는 문제를 재현하는 최소한의 익명화된 JSON만 사용합니다.

## 6. 먼저 기준 결과 만들기

같은 문서로 현재 결과를 생성합니다.

```bash
# 작업지시서
python -m src.extract_work_order /경로/작업지시서.pdf --with-confidence

# TechPack
python -m src.extract_techpack /경로/TechPack.pdf --out output/baseline
```

결과를 다음 순서로 비교합니다.

1. 원본 PDF에 값이 실제로 있는지 확인합니다.
2. `*.raw.json` 안의 `result.contents[].fields` 또는 `contents[].fields`에 값이 들어왔는지 확인합니다.
3. 정제된 `*.json`의 값이 올바른지 확인합니다.
4. Excel 변환이 구현된 경우 마지막으로 행, 컬럼, 셀 값을 확인합니다. 현재 저장소에서는 TechPack만 해당합니다.

Excel부터 바로 고치지 않는 이유는 **추출 문제**와 **Excel 변환 문제**를 구분하기 위해서입니다.

## 7. 문제가 생긴 위치를 찾는 네 가지 질문

### 질문 1: 원본 문서에 필요한 값이 있는가?

- 없다면 AI가 추출할 수 없습니다.
- 사용자에게 기본값, 계산식 또는 다른 데이터 출처가 있는지 확인합니다.
- 문서에 없는 값을 추측해서 채우지 않습니다.

### 질문 2: RAW JSON의 `fields`에 값이 올바르게 들어왔는가?

- 먼저 `result.contents[]` 또는 `contents[]` 안의 `markdown`과 `tables`에서 원문이 읽혔는지 확인합니다.
- 원문은 읽혔지만 `fields`만 누락되거나 틀렸다면 스키마 설명·타입·구조를 확인합니다.
- 원문 자체가 없거나 심하게 깨졌다면 스캔 품질, 지원 파일 형식·크기·페이지 제한, OCR·layout 설정을 확인합니다.
- 모든 구조화 필드가 비어 있다면 분석기 스키마를 확인합니다.
- 401/403 또는 `DeploymentIdNotFound` 오류가 있다면 `.env`, RBAC 역할과
  `python -m src.setup_defaults`의 기본 모델 매핑을 먼저 확인합니다.
- `src/schema.py` 또는 `src/techpack_schema.py`를 바꾼 뒤에는 분석기를 재생성합니다.

### 질문 3: RAW JSON은 맞지만 정제 JSON이 틀렸는가?

- 평탄화 또는 값 정리 코드의 문제입니다.
- `src/extract_work_order.py`의 `_simplify_field()` 같은 로컬 Python 코드를 확인합니다.
- 분석기를 재생성할 필요는 없습니다.

### 질문 4: 정제 JSON은 맞지만 Excel이 틀렸는가?

- 고객별 출력 변환 문제입니다.
- 행 수와 값 배치는 `unpivot_rows()` 같은 변환 함수를 확인합니다.
- 시트명, 헤더, 너비는 `write_excel()` 같은 Excel 작성 함수를 확인합니다.
- 분석기를 재생성할 필요는 없습니다.

한눈에 보면 다음과 같습니다.

| 현재 상태 | 고칠 곳 | 분석기 재생성 |
| --- | --- | --- |
| RAW의 `markdown`/`tables`에도 원문이 없음 | 입력 품질·지원 제한·OCR·layout | 분석기 설정 변경 시 필요 |
| 원문은 읽혔지만 `fields`가 틀림 | 스키마 설명·타입·구조 | 필요 |
| 분석은 성공했지만 모든 구조화 필드가 비어 있음 | 분석기 스키마 | 필요 |
| 401/403 또는 `DeploymentIdNotFound` | 인증·RBAC·기본 모델 매핑 | 불필요 |
| RAW 필드는 맞지만 정제 JSON이 틀림 | 평탄화·정규화 코드 | 불필요 |
| 정제 JSON은 맞지만 Excel 값·행이 틀림 | 출력 변환 함수 | 불필요 |
| 값은 맞지만 Excel 모양이 틀림 | Excel 작성 함수 | 불필요 |

## 8. 피드백을 코드 규칙으로 바꾸는 방법

“결과가 이상해요”만으로는 코드를 안전하게 고치기 어렵습니다. 피드백을 다음 형식으로 구체화합니다.

```text
입력 문서/페이지:
현재 결과:
원하는 결과:
모든 문서에 적용할 일반 규칙:
예외:
```

예시는 다음과 같습니다.

| 사용자 피드백 | 코드로 옮긴 규칙 | 테스트할 내용 |
| --- | --- | --- |
| 모든 소재를 컬러웨이별로 한 행씩 만들어 주세요 | 소재 × 컬러웨이 조합마다 행 생성 | 소재 2개 × 컬러웨이 2개 = 4행 |
| 빈 COMPONENT는 위 그룹명을 사용해 주세요 | 직전 그룹명을 다음 소재에 이어서 사용 | 헤더 다음 소재의 COMPONENT 확인 |
| 가격에서 SP24와 LIST를 빼 주세요 | 통화, 금액, 단위만 남김 | `$3.200 yd SP24` → `$3.200 yd` |
| 납기일이 자꾸 빠져요 | 실제 문서의 별칭을 스키마 설명에 추가 | 해당 양식 재분석 |

핵심 원칙은 **피드백 한 건마다 규칙 한 개와 테스트 한 개를 남기는 것**입니다.

## 9. 한 번에 한 단계만 수정하기

다음 순서로 반복하면 원인을 찾기 쉽습니다.

1. 현재 결과를 저장합니다.
2. 문제가 추출인지 Excel 변환인지 구분합니다.
3. 한 계층의 코드만 수정합니다.
4. 같은 샘플로 다시 실행합니다.
5. 회귀 테스트를 실행합니다.
6. 목표 Excel과 다시 비교합니다.
7. 사용자의 확인을 받습니다.
8. 다음 피드백으로 넘어갑니다.

스키마와 Excel 변환을 동시에 크게 수정하면 어느 변경이 결과를 개선하거나 망가뜨렸는지 알기 어렵습니다.

## 10. 새 문서 형식이 추가될 때

다음 순서로 판단합니다.

```text
새 문서
   │
   ├─ 기존 문서와 필요한 값의 의미가 같은가?
   │      ├─ 예 → 기존 분석기로 먼저 실행
   │      │          ├─ JSON이 맞음 → 분석기 재사용
   │      │          └─ 별칭 때문에 누락 → 스키마 설명 보강
   │      └─ 아니요 → 새 문서군용 스키마와 분석기 추가
   │
   ├─ 목표 Excel만 다른가?
   │      └─ 예 → 출력 변환기만 추가
   │
   └─ 문서 종류를 자동으로 선택해야 하는가?
          └─ 예 → 분류기/라우터 추가
```

분석기를 여러 개 사용하더라도 같은 의미의 값은 가능하면 같은 JSON 키를 사용합니다.

```text
dueDate
customer
lineItems
totals
```

그래야 하나의 출력 변환기를 여러 분석 결과에 재사용하기 쉽습니다.

## 11. 새 고객 Excel 형식이 추가될 때

현재 `src/extract_techpack.py`가 좋은 예입니다.

1. 분석기는 문서에서 업무 데이터를 추출합니다.
2. `unpivot_rows()`는 정제 JSON을 Excel 행으로 바꿉니다.
3. `write_excel()`은 행을 실제 Excel 파일로 저장합니다.

새 고객 양식도 같은 방식으로 나눕니다. 아래 코드는 완성 코드가 아니라 역할을 보여주는 뼈대입니다.

```python
def build_customer_rows(fields):
    rows = []
    # 사용자에게 확인받은 규칙으로 fields를 rows에 추가
    return rows


def write_customer_excel(rows, path):
    # openpyxl 등으로 헤더와 행을 저장
    raise NotImplementedError
```

특정 샘플의 행 번호나 문자열을 코드에 직접 고정하지 않습니다. 여러 문서에 적용할 수 있도록 사용자에게
확인받은 일반 규칙을 구현합니다.

## 12. 자주 사용하는 명령

```bash
# 작업지시서 스키마를 바꾼 경우
python -m src.create_analyzer --recreate
python -m src.extract_work_order /경로/작업지시서.pdf

# TechPack 스키마를 바꾼 경우
python -m src.extract_techpack /경로/TechPack.pdf --recreate-analyzer

# Python 후처리만 바꾼 경우
python -m unittest discover -s tests -v
```

`--recreate-analyzer`는 스키마나 분석기 모델을 바꿨을 때만 사용합니다. Excel 행, 값 정리,
서식 코드만 바꿨다면 분석기를 다시 만들 필요가 없습니다.

## 13. 완료 여부 체크리스트

다음 항목이 모두 만족되면 해당 문서군과 고객용 처리가 안정된 것으로 판단할 수 있습니다.

- [ ] 정상 문서뿐 아니라 표 구조와 빈 값이 다른 대표 문서도 처리한다.
- [ ] 정제 JSON의 핵심 필드가 원본 문서와 일치한다.
- [ ] Excel의 시트, 컬럼 순서, 행 수와 핵심 셀이 목표 파일과 일치한다.
- [ ] 사용자 피드백이 코드 규칙과 회귀 테스트로 남아 있다.
- [ ] 특정 파일명, 행 번호, 고객 데이터가 코드에 하드코딩되어 있지 않다.
- [ ] 새 형식이 기존 분석기로 처리되는지 먼저 확인한 뒤 필요한 경우에만 분석기를 추가했다.

## 참고 문서

- [Content Understanding custom analyzer 만들고 개선하기](https://learn.microsoft.com/azure/ai-services/content-understanding/how-to/customize-analyzer-content-understanding-studio)
- [Content Understanding으로 분류하고 분석기에 라우팅하기](https://learn.microsoft.com/azure/ai-services/content-understanding/how-to/classification-content-understanding-studio)
- [Content Understanding 지원 모델·제한](https://learn.microsoft.com/azure/ai-services/content-understanding/service-limits)
- [GitHub Copilot CLI 사용하기](https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli)

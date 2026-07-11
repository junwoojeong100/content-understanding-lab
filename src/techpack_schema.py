"""TechPack BILL OF MATERIALS(자재명세서) 필드 스키마.

의류 TechPack 의 BOM 표를 Azure AI Content Understanding 으로 구조화 추출하기 위한
스키마. 표는 *소재 행 × 컬러웨이 열* 구조의 와이드 테이블이므로, 각 소재(material)
아래에 컬러웨이별 색상(colorVariants) 을 *object 의 array* 로 담는다.

추출 결과(JSON)는 후처리에서 (소재 × 컬러웨이) 로 **언피벗**되어 고객 Excel 양식
(Style, COLORWAY, Section, WEB#/ID#, DESCRIPTION, QUALITY DETAILS, SUPPLIER,
ARTICLE#, ITEM COLOR, UOM, Item Price, COMPONENT)으로 변환된다.
"""

from __future__ import annotations

from azure.ai.contentunderstanding.models import (
    ContentFieldDefinition,
    ContentFieldSchema,
    ContentFieldType,
    GenerationMethod,
)

SCHEMA_NAME = "techpack_bom_schema"
SCHEMA_DESCRIPTION = "의류 TechPack BILL OF MATERIALS(자재명세서)에서 추출하는 데이터 스키마"


def _s(description: str, method: GenerationMethod = GenerationMethod.GENERATE) -> ContentFieldDefinition:
    """문자열 필드 헬퍼."""
    return ContentFieldDefinition(type=ContentFieldType.STRING, method=method, description=description)


def build_techpack_schema() -> ContentFieldSchema:
    """TechPack BOM 전체 필드 스키마를 생성한다."""

    # 컬러웨이별 색상 한 칸 (소재 행 안의 색상 컬럼 1개)
    color_variant = ContentFieldDefinition(
        type=ContentFieldType.OBJECT,
        method=GenerationMethod.GENERATE,
        description="해당 소재 행의 컬러웨이별 색상 1칸",
        properties={
            "colorway": _s(
                "컬러웨이 이름. 표 상단 색상 컬럼 헤더와 동일해야 함 "
                "(예: 'TWILIGHT CLOUD N47', 'SCARLET RED MICA STONE N45', "
                "'DEEP NAVY 092', 'LIGHT GRAY 039', 'BLACK 001')"
            ),
            "itemColor": _s(
                "해당 컬러웨이 칸의 ITEM COLOR 값. 셀에 보이는 그대로 표기 "
                "(예: 'DEEP NAVY - 092', 'BLACK - 001', '(Excluded)', "
                "'(Not Colorable)', 'TWILIGHT CLOUDS - TBD'). 비어있으면 빈 문자열"
            ),
        },
    )

    # 소재(자재) 한 행
    material = ContentFieldDefinition(
        type=ContentFieldType.OBJECT,
        method=GenerationMethod.GENERATE,
        description="BOM 표의 자재 한 행(행 전체에 걸친 5개 컬러웨이 색상 포함)",
        properties={
            "component": _s(
                "이 자재가 속한 **회색 배경의 전체 너비 그룹 헤더**(COMPONENT). 표 안에서 "
                "색이 칠해진 굵은 구분 행이며, 다음 회색 헤더가 나오기 전까지 그 아래 모든 "
                "자재 행에 **동일하게** 적용된다(헤더는 행마다 반복되지 않으므로 위에서 이어받음). "
                "이 문서의 그룹 헤더 예: 'Fabric', 'Trims - Active', 'Zippers - Active', "
                "'Thread', 'Labels - S23 Update', 'Packaging'. "
                "주의: Material 칼럼 첫 줄('Woven / Plain', 'Narrow Goods / Elastic', "
                "'Embellishments / Heat Transfer' 등)은 section 이며 component 가 아니다"
            ),
            "section": _s(
                "자재 구성/유형. Material 칼럼 **첫 줄**(회색 그룹 헤더가 아님) "
                "(예: 'Woven / Plain', 'Knit / Jersey - Single', 'Knit / Pique - Single', "
                "'Embellishments / Heat Transfer', 'Narrow Goods / Elastic', "
                "'Zipper / Coil Teeth and Tape')"
            ),
            "webId": _s(
                "WEB# / ID# 코드. Material 칼럼에서 section 바로 아래의 짧은 코드 "
                "(예: 'LSVO', 'LT6I', 'M8J0', 'MJOZ', 'LN6V', 'MKND', 'THREAD-6')"
            ),
            "description": _s(
                "DESCRIPTION. Material 칼럼의 품번/자재 설명을 **보이는 전체 원문 그대로** "
                "추출한다. SKU 코드 뒤의 콜론과 설명도 자르지 않는다. "
                "예: 'FVF4895QD: RECYCLED STRETCH WOVEN...', "
                "'FVF4895QDPR200040 PRINTED...', 'DT5613 MSPORT 150...', "
                "'PACKING TRIM inclusive of: CARTON LABEL'. "
                "코드가 없는 일반 자재명은 첫 단어만 남기지 말고 전체 명칭을 보존한다. "
                "Excel 변환 단계에서 명확한 영숫자 SKU 코드가 있을 때만 코드를 분리한다"
            ),
            "qualityDetails": _s(
                "Quality Details 칼럼 전체 텍스트 (예: '86% Polyester, 14% Elastane / "
                "Woven / Plain / 55.0 in cuttable / 124.0 g/m2 / ...'). 줄바꿈 포함 원문"
            ),
            "supplier": _s(
                "Supplier(공급사) 이름. 'Supplier / Article # / Size' 칼럼 첫 부분 "
                "(예: 'Everest Textile Co Ltd', 'Designer Textiles International - VN', "
                "'AVERY DENNISON', 'YKK')"
            ),
            "articleNumber": _s(
                "ARTICLE#(품번). 'Supplier / Article # / Size' 칼럼의 article 코드 "
                "(예: 'FVF4895QD', 'DT5613', 'RP3M0032-SD02AT', 'CB673921A')"
            ),
            "price": _s(
                "Item Price. Price 칼럼의 단가만: 통화기호+숫자+단위 "
                "(예: '$3.200 yd', '$10.480 m', '$63.000 ea', '$39.850 1000'). "
                "단가 아래의 'SP24'/'LIST' 같은 가격구분/시즌 태그는 **제외**한다"
            ),
            "uom": _s(
                "UOM(단위). Price/Qty 의 단위만 (예: 'yd', 'm', 'ea', '1000')"
            ),
            "colorVariants": ContentFieldDefinition(
                type=ContentFieldType.ARRAY,
                method=GenerationMethod.GENERATE,
                description=(
                    "이 자재 행의 모든 컬러웨이 색상 칸. 표의 색상 컬럼 순서(좌→우)대로, "
                    "문서의 컬러웨이 개수(보통 5개)만큼. 각 칸의 colorway 헤더와 itemColor 값"
                ),
                item_definition=color_variant,
            ),
        },
    )

    fields: dict[str, ContentFieldDefinition] = {
        "style": _s(
            "스타일 번호(Style). 페이지 상단 헤더의 'SW...' 코드 "
            "(예: 'SW002394'). 'SW002394-Mens Active Lined 5 Short' 에서 'SW002394'"
        ),
        "styleName": _s("스타일 명칭 (예: 'Mens Active Lined 5 Short')"),
        "season": _s("시즌 (예: 'SP24')"),
        "vendor": _s("벤더/제조사 (예: 'YOUNGONE CORPORATION')"),
        "brand": _s("브랜드 (예: 'Smartwool')"),
        "colorways": ContentFieldDefinition(
            type=ContentFieldType.ARRAY,
            method=GenerationMethod.GENERATE,
            description=(
                "문서 전체 컬러웨이 목록. BOM 표 상단의 색상 컬럼 헤더들을 좌→우 순서로 "
                "(예: ['TWILIGHT CLOUD N47','SCARLET RED MICA STONE N45','DEEP NAVY 092',"
                "'LIGHT GRAY 039','BLACK 001'])"
            ),
            item_definition=_s("컬러웨이 이름 1개"),
        ),
        "materials": ContentFieldDefinition(
            type=ContentFieldType.ARRAY,
            method=GenerationMethod.GENERATE,
            description=(
                "BOM 표의 모든 자재 행. 모든 페이지에 걸친 모든 행을 빠짐없이 포함. "
                "각 행은 component/section/webId/description/qualityDetails/supplier/"
                "articleNumber/price/uom 와 컬러웨이별 colorVariants 를 가진다"
            ),
            item_definition=material,
        ),
    }

    return ContentFieldSchema(name=SCHEMA_NAME, description=SCHEMA_DESCRIPTION, fields=fields)

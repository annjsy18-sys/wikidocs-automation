# -*- coding: utf-8 -*-
"""
쿠팡 파트너스 Search API 모듈 (shared).
다른 블로그 폴더(01, 02, ...)에서 공통으로 불러다 쓰는 검색 함수.

사용 전 준비:
- shared/.env 파일에 아래 두 줄을 채워두세요 (git에 절대 올리지 말 것):
    COUPANG_ACCESS_KEY=발급받은값
    COUPANG_SECRET_KEY=발급받은값

CLI 사용법:
    python coupang_api.py "퍼실 액체세제" "타이드 파즈 캡슐세제" --out results.json
"""

import os
import sys
import json
import time
import hmac
import hashlib
import argparse
import urllib.parse
from time import gmtime, strftime

import requests

# .env 파일이 있으면 읽어서 환경변수로 등록 (python-dotenv 없이 최소 구현)
def load_env(env_path: str = None):
    env_path = env_path or os.path.join(os.path.dirname(__file__), ".env")
    if not os.path.exists(env_path):
        return
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())


load_env()

ACCESS_KEY = os.environ.get("COUPANG_ACCESS_KEY", "")
SECRET_KEY = os.environ.get("COUPANG_SECRET_KEY", "")

DOMAIN = "https://api-gateway.coupang.com"
SEARCH_PATH = "/v2/providers/affiliate_open_api/apis/openapi/products/search"

# 쿠팡 파트너스 공식 제한: 상품 검색 API는 분당 최대 50회
CALLS_PER_MINUTE_LIMIT = 50
CALL_DELAY_SECONDS = 60 / CALLS_PER_MINUTE_LIMIT  # 약 1.2초


def generate_hmac(method: str, url: str, secret_key: str, access_key: str) -> str:
    path, *query = url.split("?")
    datetime_gmt = strftime("%y%m%d", gmtime()) + "T" + strftime("%H%M%S", gmtime()) + "Z"
    message = datetime_gmt + method + path + (query[0] if query else "")
    signature = hmac.new(
        bytes(secret_key, "utf-8"), message.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    return (
        f"CEA algorithm=HmacSHA256, access-key={access_key}, "
        f"signed-date={datetime_gmt}, signature={signature}"
    )


def search_products(keyword: str, limit: int = 5) -> list:
    """키워드로 상품 검색. 각 결과의 productUrl은 이미 파트너스 추적 링크임."""
    if not ACCESS_KEY or not SECRET_KEY:
        raise RuntimeError(
            "COUPANG_ACCESS_KEY / COUPANG_SECRET_KEY가 설정되지 않았습니다. "
            "shared/.env 파일을 확인하세요."
        )

    query = urllib.parse.urlencode({"keyword": keyword, "limit": limit})
    url_path_with_query = f"{SEARCH_PATH}?{query}"
    auth_header = generate_hmac("GET", url_path_with_query, SECRET_KEY, ACCESS_KEY)

    response = requests.get(
        DOMAIN + url_path_with_query,
        headers={
            "Authorization": auth_header,
            "Content-Type": "application/json;charset=UTF-8",
        },
        timeout=10,
    )

    if response.status_code != 200:
        print(f"  [오류] '{keyword}' 검색 실패: HTTP {response.status_code} - {response.text}")
        return []

    body = response.json()
    if body.get("rCode") != "0":
        print(f"  [오류] '{keyword}' 응답 코드 비정상: {body}")
        return []

    return body.get("data", {}).get("productData", [])


def search_many(keywords: list, limit: int = 5) -> dict:
    """여러 키워드를 순서대로 검색. 분당 50회 제한을 지키도록 호출 사이에 대기."""
    results = {}
    for i, kw in enumerate(keywords, start=1):
        print(f"[{i}/{len(keywords)}] '{kw}' 검색 중...")
        products = search_products(kw, limit=limit)
        simplified = []
        for p in products:
            simplified.append(
                {
                    "rank": p.get("rank"),
                    "productName": p.get("productName"),
                    "productImage": p.get("productImage"),
                    "productUrl": p.get("productUrl"),
                    "isRocket": p.get("isRocket"),
                    "isFreeShipping": p.get("isFreeShipping"),
                    # productPrice는 의도적으로 저장하지 않음
                    # (쿠팡 파트너스 규정상 글에 가격을 직접 명시하면 안 됨)
                }
            )
        results[kw] = simplified
        if i < len(keywords):
            time.sleep(CALL_DELAY_SECONDS)
    return results


def main():
    parser = argparse.ArgumentParser(description="쿠팡 파트너스 상품 검색")
    parser.add_argument("keywords", nargs="+", help="검색할 키워드들")
    parser.add_argument("--limit", type=int, default=5, help="키워드당 결과 수 (기본 5)")
    parser.add_argument("--out", default="coupang_search_results.json", help="출력 파일 경로")
    args = parser.parse_args()

    results = search_many(args.keywords, limit=args.limit)

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

    print(f"\n완료! 결과가 {args.out} 에 저장되었습니다.")


if __name__ == "__main__":
    main()

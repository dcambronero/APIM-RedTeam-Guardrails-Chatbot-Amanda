"""
Carga la base de conocimiento de Amanda en Azure AI Search.
Se ejecuta desde GitHub Actions (o localmente) y es idempotente:
borra y recrea el índice en cada ejecución.

Variables de entorno:
  AOAI_ENDPOINT     https://aoai-xxx.openai.azure.com/
  AOAI_KEY          key de Azure OpenAI
  EMBED_DEPLOYMENT  text-embedding-3-small
  SEARCH_ENDPOINT   https://srch-xxx.search.windows.net
  SEARCH_ADMIN_KEY  admin key de AI Search
  SEARCH_INDEX      amanda-kb
"""
import hashlib
import os
import pathlib
import re
import sys
import time

import httpx

AOAI = os.environ["AOAI_ENDPOINT"].rstrip("/")
AOAI_KEY = os.environ["AOAI_KEY"]
EMBED = os.environ.get("EMBED_DEPLOYMENT", "text-embedding-3-small")
SEARCH = os.environ["SEARCH_ENDPOINT"].rstrip("/")
SEARCH_KEY = os.environ["SEARCH_ADMIN_KEY"]
INDEX = os.environ.get("SEARCH_INDEX", "amanda-kb")
SEARCH_API = "2024-07-01"
AOAI_API = "2024-10-21"
DATA = pathlib.Path(__file__).resolve().parent.parent / "data" / "rag"

INDEX_SCHEMA = {
    "name": INDEX,
    "fields": [
        {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
        {"name": "title", "type": "Edm.String", "searchable": True, "analyzer": "es.microsoft"},
        {"name": "content", "type": "Edm.String", "searchable": True, "analyzer": "es.microsoft"},
        {"name": "source", "type": "Edm.String", "filterable": True},
        {
            "name": "contentVector",
            "type": "Collection(Edm.Single)",
            "searchable": True,
            "dimensions": 1536,
            "vectorSearchProfile": "default-profile",
        },
    ],
    "vectorSearch": {
        "algorithms": [{"name": "hnsw", "kind": "hnsw"}],
        "profiles": [{"name": "default-profile", "algorithm": "hnsw"}],
    },
}


def chunks(path: pathlib.Path):
    """Un chunk por sección '## ' (con el título del documento como contexto)."""
    text = path.read_text(encoding="utf-8")
    doc_title = (re.search(r"^# (.+)$", text, re.M) or [None, path.stem])[1]
    parts = re.split(r"\n(?=## )", text)
    for i, part in enumerate(parts):
        part = part.strip()
        if not part or not re.sub(r"^#+ .*$", "", part, flags=re.M).strip():
            continue  # omite chunks que solo tienen el título
        sub = re.search(r"^## (.+)$", part, re.M)
        title = f"{doc_title} · {sub.group(1)}" if sub else doc_title
        yield {
            "id": hashlib.md5(f"{path.name}-{i}".encode()).hexdigest(),
            "title": title,
            "content": part,
            "source": path.name,
        }


def embed(client: httpx.Client, text: str) -> list[float]:
    url = f"{AOAI}/openai/deployments/{EMBED}/embeddings?api-version={AOAI_API}"
    for attempt in range(6):
        r = client.post(url, headers={"api-key": AOAI_KEY}, json={"input": text})
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(5 * (attempt + 1))
            continue
        r.raise_for_status()
        return r.json()["data"][0]["embedding"]
    raise RuntimeError("embedding failed after retries")


def main() -> int:
    h = {"api-key": SEARCH_KEY, "Content-Type": "application/json"}
    with httpx.Client(timeout=60) as c:
        c.delete(f"{SEARCH}/indexes/{INDEX}?api-version={SEARCH_API}", headers=h)
        r = c.put(f"{SEARCH}/indexes/{INDEX}?api-version={SEARCH_API}", headers=h, json=INDEX_SCHEMA)
        if r.status_code >= 400:
            print(r.text)
            r.raise_for_status()
        print(f"✔ índice '{INDEX}' creado")

        docs = []
        for f in sorted(DATA.glob("*.md")):
            for ch in chunks(f):
                ch["contentVector"] = embed(c, f"{ch['title']}\n{ch['content']}")
                ch["@search.action"] = "upload"
                docs.append(ch)
                print(f"  · {ch['title']}")

        r = c.post(f"{SEARCH}/indexes/{INDEX}/docs/index?api-version={SEARCH_API}", headers=h,
                   json={"value": docs})
        if r.status_code >= 400:
            print(r.text)
            r.raise_for_status()
        print(f"✔ {len(docs)} chunks cargados")
    return 0


if __name__ == "__main__":
    sys.exit(main())

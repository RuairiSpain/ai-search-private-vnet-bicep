# Python to load documents from Onlake Lakehouse into Azure AI Search index 

```bash
  pip install -U azure-search-documents  azure-identity openai requests
  python onelake_vector_search_async.py deploy
  python onelake_vector_search_async.py query "What are the main migration dependencies?" --top 5
```

### Environment Variables
```bash
export AZURE_SEARCH_ENDPOINT="https://<search-service>.search.windows.net"
export AZURE_SEARCH_ADMIN_KEY="<optional-admin-key>"
export AZURE_SEARCH_QUERY_KEY="<optional-query-key>"
export AZURE_SEARCH_INDEX_NAME="rag-documents-index-v2"

export AZURE_OPENAI_ENDPOINT="https://<openai-resource>.openai.azure.com"
export AZURE_OPENAI_API_KEY="<optional-openai-key>"
export AZURE_OPENAI_EMBEDDING_DEPLOYMENT="<deployment-name>"

export FABRIC_WORKSPACE_ID="<workspace-guid>"
export FABRIC_LAKEHOUSE_ID="<lakehouse-guid>"

# Optional subfolder under the lakehouse Files area
export ONELAKE_FOLDER="Documents"

# Optional; defaults to every 30 minutes
export INDEXER_INTERVAL="PT30M"

```

### Ingestion Code
```python
"""Create and query a chunked OneLake -> Azure AI Search vector index.

Uses:
- Azure OpenAI text-embedding-3-small, 1024 dimensions
- Azure AI Search built-in int8 scalar quantisation
- OneLake files indexer
- Token-aware chunking: 2,000 tokens, 400-token overlap
- Async hybrid + semantic vector query
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
from typing import Any

import requests
from azure.core.credentials import AzureKeyCredential
from azure.identity import DefaultAzureCredential
from azure.search.documents.aio import SearchClient
from azure.search.documents.models import VectorizedQuery
from openai import AsyncAzureOpenAI

API_VERSION = os.getenv("AZURE_SEARCH_API_VERSION", "2026-04-01")
INDEX_NAME = os.getenv("AZURE_SEARCH_INDEX_NAME", "rag-documents-index-v2")
DATASOURCE_NAME = f"{INDEX_NAME}-onelake"
SKILLSET_NAME = f"{INDEX_NAME}-skillset"
INDEXER_NAME = f"{INDEX_NAME}-indexer"
EMBEDDING_DIMENSIONS = 1024
CHUNK_TOKENS = 2000
CHUNK_OVERLAP_TOKENS = 400


def required(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing environment variable: {name}")
    return value


def search_headers() -> dict[str, str]:
    key = os.getenv("AZURE_SEARCH_ADMIN_KEY")
    if key:
        return {"api-key": key, "Content-Type": "application/json"}
    token = DefaultAzureCredential().get_token("https://search.azure.com/.default")
    return {"Authorization": f"Bearer {token.token}", "Content-Type": "application/json"}


def put_search_resource(resource_path: str, name: str, body: dict[str, Any]) -> None:
    endpoint = required("AZURE_SEARCH_ENDPOINT").rstrip("/")
    url = f"{endpoint}/{resource_path}/{name}?api-version={API_VERSION}"
    response = requests.put(url, headers=search_headers(), json=body, timeout=120)
    if not response.ok:
        raise RuntimeError(f"PUT {resource_path}/{name} failed: {response.status_code} {response.text}")
    print(f"Created/updated {resource_path}/{name}")


def post_search_resource(resource_path: str, name: str, action: str) -> None:
    endpoint = required("AZURE_SEARCH_ENDPOINT").rstrip("/")
    url = f"{endpoint}/{resource_path}/{name}/{action}?api-version={API_VERSION}"
    response = requests.post(url, headers=search_headers(), timeout=120)
    if not response.ok:
        raise RuntimeError(
            f"POST {resource_path}/{name}/{action} failed: "
            f"{response.status_code} {response.text}"
        )
    print(f"Started {resource_path}/{name}/{action}")


def index_definition() -> dict[str, Any]:
    # Based on sample-indexes-v2.json. Important fixes:
    # 1. dimensions changed from 1536 to 1024
    # 2. vectorSearchProfile assigned to each vector field
    # 3. content/title made searchable for hybrid + semantic search
    # 4. documentCode is the parent key populated by index projections
    return {
        "name": INDEX_NAME,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "searchable": False,
             "filterable": True, "sortable": True, "facetable": False},
            {"name": "documentCode", "type": "Edm.String", "searchable": False,
             "filterable": True, "sortable": True, "facetable": True},
            {"name": "title", "type": "Edm.String", "searchable": True,
             "filterable": False, "sortable": False, "facetable": False},
            {"name": "content", "type": "Edm.String", "searchable": False,
             "filterable": False, "sortable": False, "facetable": False},
            {"name": "category", "type": "Edm.String", "searchable": True,
             "filterable": True, "sortable": True, "facetable": True},
            {"name": "sourceFile", "type": "Edm.String", "searchable": True,
             "filterable": True, "sortable": True, "facetable": True},
            {"name": "publishedDate", "type": "Edm.DateTimeOffset",
             "filterable": True, "sortable": True, "facetable": True},
            {"name": "lastUpdated", "type": "Edm.DateTimeOffset",
             "filterable": True, "sortable": True, "facetable": True},
            {"name": "businessUnit", "type": "Edm.String", "searchable": True,
             "filterable": True, "sortable": True, "facetable": True},
            {"name": "group_ids", "type": "Collection(Edm.String)",
             "searchable": False, "filterable": True, "facetable": True},
            {"name": "titleVector", "type": "Collection(Edm.Single)",
             "searchable": True, "retrievable": False, "stored": False,
             "dimensions": EMBEDDING_DIMENSIONS,
             "vectorSearchProfile": "default-vector-profile"},
            {"name": "contentVector", "type": "Collection(Edm.Single)",
             "searchable": True, "retrievable": False, "stored": False,
             "dimensions": EMBEDDING_DIMENSIONS,
             "vectorSearchProfile": "default-vector-profile"},
        ],
        "vectorSearch": {
            "compressions": [{
                "name": "scalar-quantization",
                "kind": "scalarQuantization",
                "scalarQuantizationParameters": {"quantizedDataType": "int8"},
                "rescoringOptions": {
                    "enableRescoring": True,
                    "defaultOversampling": 10,
                    "rescoreStorageMethod": "discardOriginals",
                },
            }],
            "algorithms": [{
                "name": "default-hnsw",
                "kind": "hnsw",
                "hnswParameters": {
                    "metric": "cosine", "m": 4,
                    "efConstruction": 400, "efSearch": 300,
                },
            }],
            "profiles": [{
                "name": "default-vector-profile",
                "algorithm": "default-hnsw",
                "compression": "scalar-quantization",
            }],
        },
        "semantic": {
            "defaultConfiguration": "default-semantic-config",
            "configurations": [{
                "name": "default-semantic-config",
                "prioritizedFields": {
                    "titleField": {"fieldName": "title"},
                    "prioritizedContentFields": [{"fieldName": "documentCode"}],
                    "prioritizedKeywordsFields": [
                        {"fieldName": "category"},
                        {"fieldName": "sourceFile"},
                    ],
                },
            }],
        },
    }


def datasource_definition() -> dict[str, Any]:
    body: dict[str, Any] = {
        "name": DATASOURCE_NAME,
        "type": "onelake",
        "credentials": {
            "connectionString": f"ResourceId={required('FABRIC_WORKSPACE_ID')}"
        },
        "container": {
            "name": required("FABRIC_LAKEHOUSE_ID"),
            "query": os.getenv("ONELAKE_FOLDER", ""),
        },
    }
    # Omit this for the Search service system-assigned managed identity.
    user_mi = os.getenv("AZURE_SEARCH_USER_ASSIGNED_IDENTITY")
    if user_mi:
        body["identity"] = {
            "@odata.type": "#Microsoft.Azure.Search.DataUserAssignedIdentity",
            "userAssignedIdentity": user_mi,
        }
    return body


def embedding_skill(name: str, context: str, source: str, target_name: str) -> dict[str, Any]:
    # The deployment name may differ from the model name.
    return {
        "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
        "name": name,
        "context": context,
        "resourceUri": required("AZURE_OPENAI_ENDPOINT"),
        "deploymentName": required("AZURE_OPENAI_EMBEDDING_DEPLOYMENT"),
        "modelName": "text-embedding-3-small",
        "dimensions": EMBEDDING_DIMENSIONS,
        "inputs": [{"name": "text", "source": source}],
        "outputs": [{"name": "embedding", "targetName": target_name}],
    }


def skillset_definition() -> dict[str, Any]:
    return {
        "name": SKILLSET_NAME,
        "skills": [
            {
                "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
                "name": "split-content-by-tokens",
                "description": "Split each OneLake file into overlapping token chunks",
                "context": "/document",
                "textSplitMode": "pages",
                "unit": "azureOpenAITokens",
                "maximumPageLength": CHUNK_TOKENS,
                "pageOverlapLength": CHUNK_OVERLAP_TOKENS,
                "azureOpenAITokenizerParameters": {"encoderModelName": "cl100k_base"},
                "inputs": [{"name": "text", "source": "/document/content"}],
                "outputs": [{"name": "textItems", "targetName": "pages"}],
            },
            embedding_skill(
                "embed-content", "/document/pages/*", "/document/pages/*", "contentVector"
            ),
            embedding_skill(
                "embed-title", "/document", "/document/metadata_storage_name", "titleVector"
            ),
        ],
        "indexProjections": {
            "selectors": [{
                "targetIndexName": INDEX_NAME,
                "parentKeyFieldName": "documentCode",
                "sourceContext": "/document/pages/*",
                "mappings": [
                    {"name": "content", "source": "/document/pages/*"},
                    {"name": "contentVector", "source": "/document/pages/*/contentVector"},
                    {"name": "title", "source": "/document/metadata_storage_name"},
                    {"name": "titleVector", "source": "/document/titleVector"},
                    {"name": "sourceFile", "source": "/document/metadata_storage_name"},
                    {"name": "lastUpdated", "source": "/document/metadata_storage_last_modified"},
                    # The following rely on custom OneLake file metadata when present.
                    {"name": "category", "source": "/document/category"},
                    {"name": "publishedDate", "source": "/document/publishedDate"},
                    {"name": "businessUnit", "source": "/document/businessUnit"},
                    {"name": "group_ids", "source": "/document/group_ids"},
                ],
            }],
            "parameters": {"projectionMode": "skipIndexingParentDocuments"},
        },
    }


def indexer_definition() -> dict[str, Any]:
    return {
        "name": INDEXER_NAME,
        "dataSourceName": DATASOURCE_NAME,
        "targetIndexName": INDEX_NAME,
        "skillsetName": SKILLSET_NAME,
        "parameters": {
            "batchSize": 10,
            "maxFailedItems": -1,
            "maxFailedItemsPerBatch": -1,
            "configuration": {
                "dataToExtract": "contentAndMetadata",
                "parsingMode": "default",
                "indexedFileNameExtensions": ".pdf,.doc,.docx,.ppt,.pptx,.txt,.md,.html,.htm,.rtf,.csv,.json",
                "failOnUnsupportedContentType": False,
                "failOnUnprocessableDocument": False,
            },
        },
        "schedule": {"interval": os.getenv("INDEXER_INTERVAL", "PT30M")},
    }


def deploy() -> None:
    # Search service identity needs Contributor on the Fabric workspace and
    # Cognitive Services OpenAI User (or equivalent) on the Azure OpenAI resource.
    put_search_resource("indexes", INDEX_NAME, index_definition())
    put_search_resource("datasources", DATASOURCE_NAME, datasource_definition())
    put_search_resource("skillsets", SKILLSET_NAME, skillset_definition())
    put_search_resource("indexers", INDEXER_NAME, indexer_definition())
    post_search_resource("indexers", INDEXER_NAME, "run")


def search_credential():
    key = os.getenv("AZURE_SEARCH_QUERY_KEY") or os.getenv("AZURE_SEARCH_ADMIN_KEY")
    return AzureKeyCredential(key) if key else DefaultAzureCredential()


async def embed_query(text: str) -> list[float]:
    client = AsyncAzureOpenAI(
        azure_endpoint=required("AZURE_OPENAI_ENDPOINT"),
        api_key=os.getenv("AZURE_OPENAI_API_KEY"),
        azure_ad_token_provider=None,
        api_version=os.getenv("AZURE_OPENAI_API_VERSION", "2024-10-21"),
    )
    # If no API key is supplied, use Entra ID.
    if not os.getenv("AZURE_OPENAI_API_KEY"):
        from azure.identity.aio import DefaultAzureCredential as AsyncDefaultAzureCredential
        from azure.identity.aio import get_bearer_token_provider
        credential = AsyncDefaultAzureCredential()
        client = AsyncAzureOpenAI(
            azure_endpoint=required("AZURE_OPENAI_ENDPOINT"),
            azure_ad_token_provider=get_bearer_token_provider(
                credential, "https://cognitiveservices.azure.com/.default"
            ),
            api_version=os.getenv("AZURE_OPENAI_API_VERSION", "2024-10-21"),
        )
    response = await client.embeddings.create(
        model=required("AZURE_OPENAI_EMBEDDING_DEPLOYMENT"),
        input=text,
        dimensions=EMBEDDING_DIMENSIONS,
    )
    await client.close()
    return response.data[0].embedding


async def query(text: str, top: int = 5) -> None:
    vector = await embed_query(text)
    vector_query = VectorizedQuery(
        vector=vector,
        k_nearest_neighbors=50,
        fields="contentVector,titleVector",
        exhaustive=False,
        oversampling=10.0,
    )
    client = SearchClient(
        endpoint=required("AZURE_SEARCH_ENDPOINT"),
        index_name=INDEX_NAME,
        credential=search_credential(),
    )
    async with client:
        results = await client.search(
            search_text=text,                  # hybrid BM25 + vector
            vector_queries=[vector_query],
            query_type="semantic",
            semantic_configuration_name="default-semantic-config",
            select=["id", "documentCode", "title", "content", "category",
                    "sourceFile", "lastUpdated", "businessUnit", "group_ids"],
            top=top,
        )
        async for result in results:
            print(json.dumps({
                "score": result.get("@search.score"),
                "rerankerScore": result.get("@search.reranker_score"),
                "title": result.get("title"),
                "sourceFile": result.get("sourceFile"),
                "content": result.get("content"),
            }, ensure_ascii=False, indent=2, default=str))


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("deploy", help="Create/update the index, OneLake source, skillset and indexer")
    query_parser = sub.add_parser("query", help="Run async hybrid semantic vector search")
    query_parser.add_argument("text")
    query_parser.add_argument("--top", type=int, default=5)
    args = parser.parse_args()
    if args.command == "deploy":
        deploy()
    else:
        asyncio.run(query(args.text, args.top))


if __name__ == "__main__":
    main()

```

Sample Queries - Vector only
```python

query_embedding = await embed_query(text)

vector_query = VectorizedQuery(
    vector=query_embedding,
    fields="contentVector,titleVector",
    k_nearest_neighbors=50,
    exhaustive=False,
    oversampling=10.0
)

results = await search_client.search(
    search_text=None,
    vector_queries=[vector_query],
    filter="""
        publishedDate ge 2026-01-01T00:00:00Z
        and category eq 'Sales'
        and businessUnit eq 'Spain'
    """,
    top=10
)

# As REST API:
POST /indexes/rag-documents-index-v2/docs/search?api-version=2026-04-01
{
  "count": true,
  "top": 10,
  "filter": "publishedDate ge 2026-01-01T00:00:00Z and category eq 'Sales' and businessUnit eq 'Spain'",
  "vectorQueries": [
    {
      "kind": "vector",
      "vector": [ ...1024 values... ],
      "fields": "contentVector,titleVector",
      "k": 50,
      "oversampling": 10
    }
  ]
}


```
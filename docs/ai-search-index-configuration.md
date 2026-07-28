# Azure AI Search index creation configuration explained

This guide explains the purpose of the main settings used when creating an Azure AI Search index for RAG, agent retrieval, hybrid search and enterprise document search.

## 1. What an Azure AI Search index is

An Azure AI Search index is similar to a database table plus search-specific behaviour. It defines:

- the fields/columns that can be stored;
- which fields can be searched, filtered, sorted or faceted;
- which fields contain vectors for semantic similarity search;
- how vector search is performed;
- which fields are used by semantic ranking.

A simplified index looks like this:

```json
{
  "name": "rag-documents-index",
  "fields": [],
  "vectorSearch": {},
  "semantic": {}
}
```

## 2. Field / column configuration

Each object in `fields` defines one index column.

```json
{
  "name": "title",
  "type": "Edm.String",
  "searchable": true,
  "filterable": false,
  "sortable": false,
  "facetable": false,
  "retrievable": true
}
```

### Common field types

| Type | Use case | Example |
|---|---|---|
| `Edm.String` | Text, IDs, names, categories | `title`, `category`, `sourceFile` |
| `Edm.Int32` / `Edm.Int64` | Whole numbers | `pageNumber`, `version`, `year` |
| `Edm.Double` | Decimal numbers | `score`, `price`, `confidence` |
| `Edm.Boolean` | Flags | `isSensitive`, `isArchived` |
| `Edm.DateTimeOffset` | Date/time filtering and sorting | `publishedDate`, `lastUpdated` |
| `Collection(Edm.String)` | Lists of values | `group_ids`, `tags`, `entities` |
| `Collection(Edm.Single)` | Vector embeddings | `titleVector`, `contentVector` |
| `Collection(Edm.ComplexType)` | Nested repeated objects | scenes, sections, extracted tables |

## 3. Core field properties

### `name`

The column name.

```json
{ "name": "documentCode" }
```

Use stable names because application code, filters and prompts often depend on them.

### `type`

The data type stored in the field.

```json
{ "type": "Edm.String" }
```

This matters because filters and sorting only work correctly when the field type matches the operation. For example, use `Edm.DateTimeOffset` for dates rather than storing dates as strings.

### `key`

Marks the unique document identifier.

```json
{
  "name": "id",
  "type": "Edm.String",
  "key": true
}
```

Only one field can be the key. Document updates and deletes use this value.

### `searchable`

Controls whether full-text search can match this field.

```json
{
  "name": "content",
  "type": "Edm.String",
  "searchable": true
}
```

Use `searchable: true` for human language fields such as `title`, `content`, `summary`, `tags` and `description`.

Do **not** enable it for everything. IDs, ACL fields, dates and numeric fields usually do not need full-text tokenisation.

### `filterable`

Controls whether the field can be used in an OData filter.

```json
{
  "name": "category",
  "type": "Edm.String",
  "filterable": true
}
```

Examples:

```text
category eq 'Policy'
publishedDate ge 2026-07-01T00:00:00Z
group_ids/any(g: search.in(g, 'finance,legal'))
```

For enterprise RAG, make metadata fields filterable: `country`, `year`, `department`, `businessUnit`, `classification`, `group_ids`, `sourceSystem`.

### `sortable`

Controls whether results can be ordered by this field.

```json
{
  "name": "publishedDate",
  "type": "Edm.DateTimeOffset",
  "sortable": true
}
```

Example:

```text
$orderby=publishedDate desc
```

Use for dates, numeric values and short metadata fields. Avoid sorting large text fields.

### `facetable`

Controls whether the field can be used to produce aggregations or buckets.

```json
{
  "name": "category",
  "type": "Edm.String",
  "facetable": true
}
```

Useful for search UI refiners:

```text
Category
- Policy (42)
- Runbook (17)
- Architecture (8)
```

Good candidates: `category`, `country`, `department`, `businessUnit`, `classification`, `sourceSystem`.

### `retrievable`

Controls whether the field is returned in search results.

```json
{
  "name": "contentVector",
  "retrievable": false
}
```

Set vector fields to `retrievable: false` unless you explicitly need to return vectors. This reduces payload size and avoids exposing unnecessary technical data.

## 4. Vector field properties

A vector field stores embeddings.

```json
{
  "name": "contentVector",
  "type": "Collection(Edm.Single)",
  "searchable": true,
  "retrievable": false,
  "dimensions": 1536,
  "vectorSearchProfile": "default-vector-profile"
}
```

### `dimensions`

The length of the embedding vector. It must match the embedding model output. THe embedding size depends on the tokenizer you choose. Tokenizer converts text into an array or floating point values. the dimension is the length or the array. Example: Tokenizer enbeds text into a vector with 1536 floating point value, dimension is 1536.

```text
contentVector : [0.0189, -0.0073, 0.1021, ... ]
1536 dimensions × 4 bytes
= 6144 bytes
≈ 6 KB per row in AI Index
```

Note, OpenAI´s text-embedding tokenizer uses MRL (Matryoshka Representation Learning), you can reduce the size of the output tokens and it truncates some of the vector precision at the end, but the vector is roughly pointing to the same vector position. The embedding dimension in the index is a parameter you can play with.  Not all tokenizers can create MRL vectors.

Examples:

| Embedding model | Typical dimensions |
|---|---:|
| `text-embedding-ada-002` | 1536 |
| `text-embedding-3-small` | configurable up to 1536 |
| `text-embedding-3-large` | configurable up to 3072 |

*If dimensions do not match, document upload or vector query calls fail. Tip: to reduce storage costs, evaluate with `1024`, should be a good balance of storage usage and quality vector. text-embedding-3-large is about x3 more expensive to tokenizer and can double your storage costs. With 400GB of data, cost per month should be considered.*

The biggest savings come from:

```text
3072 → 1024 dimensions (3× smaller)
float32 → int8 quantization (4× smaller) (I'll cover quantization later)
```

*Can get a x12 savings on index storage by dialing in your settings. But need to evaluate Precision and Recall of sample Search queries.*

### `vectorSearchProfile`

Links the vector field to a vector search profile.

```json
"vectorSearchProfile": "default-vector-profile"
```

The profile then points to an algorithm configuration:

```text
contentVector
  -> default-vector-profile
    -> default-hnsw
```

This lets multiple vector fields share the same vector search settings.

## 5. Advanced field properties

### `analyzer`

Controls how text is tokenised and processed.

```json
{
  "name": "content",
  "type": "Edm.String",
  "searchable": true,
  "analyzer": "en.microsoft"
}
```

Useful for language-aware stemming and tokenisation.

### `searchAnalyzer` and `indexAnalyzer`

Use different analyzers at indexing time and query time.

```json
{
  "name": "content",
  "type": "Edm.String",
  "searchable": true,
  "indexAnalyzer": "en.microsoft",
  "searchAnalyzer": "standard.lucene"
}
```

Use only when you have a strong reason; it adds complexity.

### `normalizer`

Normalises filterable/sortable strings, for example lower-casing exact-match fields.

```json
{
  "name": "category",
  "type": "Edm.String",
  "filterable": true,
  "normalizer": "lowercase"
}
```

### `synonymMaps`

Adds synonym expansion for search queries.

```json
{
  "name": "content",
  "type": "Edm.String",
  "searchable": true,
  "synonymMaps": ["enterprise-synonyms"]
}
```

Examples:

```text
HR => Human Resources
AI Search => Azure AI Search
private endpoint => Private Link
```

### `stored`

Controls whether vector data is stored separately for retrieval. For many RAG workloads, vectors should not be returned to callers, so keep vector fields non-retrievable and consider storage-related optimisations carefully.

## 6. Vector search configuration

Example:

```json
"vectorSearch": {
  "algorithms": [
    {
      "name": "default-hnsw",
      "kind": "hnsw",
      "hnswParameters": {
        "metric": "cosine",
        "m": 4,
        "efConstruction": 400,
        "efSearch": 500
      }
    }
  ],
  "profiles": [
    {
      "name": "default-vector-profile",
      "algorithm": "default-hnsw"
    }
  ]
}
```

### `algorithms`

Defines one or more vector search algorithms.

Azure AI Search commonly uses:

1. *"hnsw"* stands for Hierarchical Navigable Small World graph, which is an efficient algorithm for approximate nearest neighbor search in high-dimensional spaces.
    * "hnsw" is generally preferred for high-dimensional vector search 
    * Balance between search accuracy and efficiency.
    * HNSW Faster choice, 95%+ correct
    * Ananogy: Jump onto a motorway, Get near the destination (estimated), Take smaller roads, Arrive at the restaurant
1. *"exhaustiveKnn"* K nearest Neighbors search is a brute-force search algorithm that finds the k nearest neighbors of a query point by exhaustively comparing it to all points in the dataset.
    * Slower (exact search), 100% correct
    * Finds the exact nearest neighbours, No approximation, Must compare against every vector,Much slower on large indexes


### HNSW explained

HNSW means **Hierarchical Navigable Small World**. It builds a graph of nearby vectors during indexing.

Conceptually:

```text
Vector A -- Vector B -- Vector C
   |          |            |
Vector D -- Vector E -- Vector F
```

Instead of comparing a query vector with every vector, search walks the graph to find near neighbours quickly.

Use HNSW for most production RAG workloads because it gives fast approximate nearest neighbour search with good recall.

### `metric`

Similarity function used to compare vectors.

```json
"metric": "cosine"
```

Common options:

| Metric | Meaning | Typical use |
|---|---|---|
| `cosine` | Compares angle/direction | Measures how similar two vectors point in the same direction, ignoring their length |
| `dotProduct` | Dot product similarity | Measures similarity using both direction and magnitude, so larger vectors can score higher than smaller ones even if they point in the same direction |
| `euclidean` | Geometric distance | Measures the straight-line distance between two vectors in space, with smaller distances meaning greater similarity |
| `hamming` | Difference count | Counts how many bits differ between two binary vectors, making it useful for compressed or binary-encoded embeddings |

For Azure OpenAI text embeddings, `cosine` is usually the sensible default.

### `m`

Controls graph connectivity: how many bi-directional links are kept per node.

```json
"m": 4
```

Lower values:

- smaller graph;
- lower RAM usage;
- faster indexing;
- potentially lower recall.

Higher values:

- better graph connectivity;
- potentially better recall;
- more RAM;
- slower indexing.

Starter value: `4`. Means:

```

vector A → up to 4 connections
vector B → up to 4 connections
vector C → up to 4 connections`
```

Typical production experimentation: `8` to `16` depending on size, cost and recall requirements.


```

4–8     Small / memory constrained
16      Common production default in many vector DBs
32–64   Very high recall
```

### `efConstruction`

How many candidate neighbours HNSW evaluates while building the graph. Controls how much effort is spent building the HNSW graph during indexing.

```json
"efConstruction": 400
```

Example: When inserting a vector, look at roughly 400 candidate neighbours before deciding which connections to keep.

Higher values:

- better graph quality;
- better future recall;
- slower indexing;
- higher build-time resource usage.

Think of it as the **index build quality knob**.

```text
100-200   Fast indexing
400       Common production value
800-1000  High-quality graph
```

### `efSearch`

How many candidates HNSW explores during a query. Controls how much of the graph is explored at query time.

```json
"efSearch": 500
```

Example: "When answering a query, investigate about 500 candidate vectors before returning the top k."

Higher values:

- better recall;
- slower queries;
- higher query-time effort.

Lower values:

- faster queries;
- may miss relevant neighbours.

Think of it as the **query recall knob**.

```text
40-100    Fast
100-300   Balanced
300-1000  High recall
```

Summary

| Setting          | Index Build | Query Speed  | Memory | Recall    |
| ---------------- | ----------- | ------------ | ------ | --------- |
| `m`              | High        | Small impact | High   | High      |
| `efConstruction` | Very high   | None         | None   | Medium    |
| `efSearch`       | None        | Very high    | None   | Very high |

### `profiles`

Profiles connect vector fields to algorithms.

```json
"profiles": [
  {
    "name": "default-vector-profile",
    "algorithm": "default-hnsw"
  }
]
```

A vector field references the profile:

```json
{
  "name": "contentVector",
  "vectorSearchProfile": "default-vector-profile"
}
```

This indirection lets you define multiple profiles:

```json
"profiles": [
  { "name": "fast-profile", "algorithm": "fast-hnsw" },
  { "name": "high-recall-profile", "algorithm": "accurate-hnsw" }
]
```

Then different vector fields can use different performance/recall settings.

### Tip to reduce costs on Large Document Index

- `scalarQuantization` - Reduce the precision of the vector floating points. Can do this for `scalarQuantization` or `binaryQuantization` only.

- `quantizedDataType: "int8"` - Stores each vector value as a 1-byte integer instead of a 4-byte float, typically reducing vector storage by about 4×. Only int8 is available in AI Search

- `enableRescoring: true` - Uses compressed vectors to find candidates quickly, then performs a second-quality check to improve accuracy.

- `defaultOversampling: 10` - Fetches roughly 10× more candidate vectors than needed before rescoring, increasing the chance of returning the best matches. Higher number solower the search, not as big a latency as ef properties.

- `rescoreStorageMethod: "discardOriginals"` - Deletes the original full-precision vectors after compression to save the most storage space. Reduce costs!

```json
 "vectorSearch": {
      "compressions": [
        {
            "name": "scalar-quantization",
            "kind": "scalarQuantization",
            "scalarQuantizationParameters": {
              "quantizedDataType": "int8"
            },
            "rescoringOptions": {
              "enableRescoring": true,
              "defaultOversampling": 10,
              "rescoreStorageMethod": "discardOriginals"
            }
        }
      ],
      "algorithms": [
        {
          "name": "default-hnsw",
          "kind": "hnsw",
          "hnswParameters": {
            "metric": "cosine",
            "m": 4,
            "efConstruction": 400,
            "efSearch": 300
          }
        }
      ],
      "profiles": [
        {
          "name": "default-vector-profile",
          "algorithm": "default-hnsw",
          "compression": "scalar-quantization"
        }
      ]
```

## 7. Semantic configuration

Semantic configuration tells semantic ranker which fields are semantically important.

```json
"semantic": {
  "defaultConfiguration": "default-semantic-config",
  "configurations": [
    {
      "name": "default-semantic-config",
      "prioritizedFields": {
        "titleField": {
          "fieldName": "title"
        },
        "prioritizedContentFields": [
          { "fieldName": "content" }
        ],
        "prioritizedKeywordsFields": [
          { "fieldName": "category" },
          { "fieldName": "sourceFile" }
        ]
      }
    }
  ]
}
```

Semantic ranker uses an initial result set and reranks it using semantic understanding.

### `defaultConfiguration`

The semantic configuration used when the query does not explicitly name one.

### `configurations`

Collection of named semantic configurations. You can create separate configurations for different content types.

Examples:

```text
policy-semantic-config
contract-semantic-config
product-semantic-config
```

### `titleField`

Short, descriptive title field.

Good examples:

- document title;
- article heading;
- product name;
- policy name.

### `prioritizedContentFields`

Long natural language fields used for semantic ranking.

Good examples:

- `content`;
- `summary`;
- `chunkText`;
- `description`.

### `prioritizedKeywordsFields`

Short keyword-like fields that help context.

Good examples:

- `category`;
- `tags`;
- `sourceFile`;
- `businessUnit`;
- `entities`.

## 8. Document cracking, chunking and enrichment

Index quality depends heavily on your ingestion pipeline.

### Document cracking

Document cracking extracts useful content from files such as Word, PDF or PowerPoint.

Typical outputs:

```json
{
  "title": "Private Networking Policy",
  "content": "Extracted document text...",
  "sourceFile": "policy.docx",
  "author": "Security Team",
  "lastModified": "2026-07-15T00:00:00Z"
}
```

### Chunking

For RAG, do not usually index a 200-page file as one document. Split it into chunks.

```json
{
  "id": "policy-001-chunk-004",
  "parentId": "policy-001",
  "chunkNumber": 4,
  "title": "Private Networking Policy",
  "content": "Chunk text here..."
}
```

Common strategies:

| Strategy | Description | Best for |
|---|---|---|
| Fixed character chunks | Split every N characters with overlap | Simple demos |
| Token chunks | Split by model token budget | LLM workflows |
| Heading-aware chunks | Split around headings and sections | Policies, manuals, Word docs |
| Table-aware chunks | Preserve tables as structured chunks | Financial, operational docs |
| Semantic chunks | Split by meaning/topic | High-quality RAG |

### Metadata enrichment

Add extracted metadata:

```json
{
  "country": "Spain",
  "year": 2026,
  "businessUnit": "Cloud",
  "language": "en",
  "tags": ["private networking", "AI Search"],
  "people": ["Ruairi O'Donnell"],
  "organisations": ["Microsoft"]
}
```

Good metadata improves exact filtering, security trimming and faceting.

### Language identification

Add language metadata:

```json
{
  "language": "es"
}
```

Use this to:

- route documents to language-specific analyzers;
- filter by language;
- choose language-specific prompts or embeddings.

### Sensitivity detection

Add sensitivity metadata:

```json
{
  "classification": "Confidential",
  "sensitivityLabel": "Highly Confidential",
  "isSensitive": true
}
```

Use sensitivity fields in filters so sensitive content is not retrieved for users who should not see it.

## 9. Suggested enterprise RAG index pattern

```json
{
  "id": "doc-001-chunk-001",
  "parentId": "doc-001",
  "title": "Private Networking Policy",
  "content": "Chunk text...",
  "summary": "Short summary...",
  "category": "Policy",
  "sourceSystem": "SharePoint",
  "sourceFile": "policy.docx",
  "businessUnit": "Cloud",
  "country": "Spain",
  "language": "en",
  "publishedDate": "2026-07-15T00:00:00Z",
  "classification": "Confidential",
  "sensitivityLabel": "Internal",
  "group_ids": ["ai-platform", "security"],
  "titleVector": [],
  "contentVector": []
}
```

Design principle: combine exact metadata, full-text content, vector fields and security fields. Do not rely on vector search alone.

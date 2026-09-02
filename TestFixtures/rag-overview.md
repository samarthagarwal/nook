# Retrieval-Augmented Generation (RAG)

A practical overview of what RAG is, where it is used, and how the field has evolved.

## What is RAG?

Retrieval-Augmented Generation combines two steps:

1. **Retrieve** relevant passages from a knowledge source (documents, databases, APIs).
2. **Generate** an answer with a language model that is conditioned on those passages.

Instead of relying only on what the model memorized during training, RAG grounds replies in content you control. That improves factual accuracy for private or fast-changing information and makes answers easier to cite.

Classic pipeline:

- Index documents (chunk → embed → store in a vector index, often with keyword/FTS search as well).
- At query time, embed the user question and fetch top‑k similar chunks.
- Build a prompt that includes the question plus retrieved text.
- Let the model answer **using** that context; optionally attach citations.

## Why teams use RAG

| Need | How RAG helps |
|------|----------------|
| Private data | Keep company docs on-device or in a private store; do not fine-tune on secrets. |
| Freshness | Update the index when docs change; no full model retrain. |
| Citations | Return source labels (file, section, page) next to claims. |
| Cost / latency | Smaller models can answer well when given the right passages. |
| Hallucination control | Instruct the model to stick to retrieved text or say when nothing relevant was found. |

RAG is not a replacement for fine-tuning. Fine-tuning changes style and skills; RAG supplies facts. Many products use both.

## Core building blocks

### Chunking

Split documents into passages of a few hundred tokens with overlap so answers are not cut mid-sentence. Section-aware chunking (by heading) usually beats naive fixed windows for manuals and wikis.

### Embeddings

Dense vectors capture semantic similarity (“capital of France” ≈ “Paris is the capital”). Sparse or lexical search (BM25 / FTS) catches exact terms, IDs, and rare names. **Hybrid retrieval** (lexical + dense) is the default in many production systems.

### Reranking

After a cheap top‑k retrieve, a cross-encoder or LLM reranker can reorder passages for precision. Useful when the first-stage index is noisy.

### Generation policy

System prompts should say when to:

- Quote or paraphrase only from retrieved text.
- Answer general knowledge if the question is not about the corpus.
- Admit “not found in scoped collections” instead of inventing document facts.

## Applications

### Enterprise knowledge assistants

Internal wikis, Confluence, Notion, PDFs, and ticket history. Employees ask policy or “how do we…” questions and get grounded answers with links.

### Customer support

Product manuals, release notes, and FAQ corpora power chatbots that cite the right article instead of improvising.

### Legal and compliance

Contract clauses, regulations, and playbooks—with strict grounding and audit trails.

### Healthcare and life sciences

Protocols and literature search under careful human review; retrieval reduces unsupported clinical claims.

### Software engineering

Codebase RAG (repos, ADRs, runbooks) for “where is X handled?” and onboarding. Often pairs symbol search with embeddings.

### On-device / private AI

Phones and laptops run a local model plus a local index (SQLite FTS, embeddings). No document text leaves the device. Good fit for personal notes, project handbooks, and regulated environments.

### Agents and tools

Agents call a `documents_search` (or similar) tool, then answer. The app can **force** search when a knowledge collection is scoped so retrieval is deterministic.

## Failure modes to design for

- **Wrong top‑k**: Irrelevant passages still look confident; use hybrid search, filters (collection scope), and score thresholds.
- **Lost in the middle**: Very long contexts bury useful chunks; keep evidence short and ordered by relevance.
- **Citation theater**: Showing source pills when the model answered from general knowledge confuses users—attach citations only when passages actually support the answer.
- **Stale index**: Docs updated but not re-chunked/re-embedded.
- **Prompt over-constraint**: “Answer only from passages” breaks simple world-knowledge questions in a scoped chat; allow general answers when retrieval is unrelated.

## Latest developments (2024–2026)

### Hybrid and graph retrieval

Dense + sparse fusion is standard. Some systems add knowledge graphs or hierarchical indexes (summary → section → chunk) for long corpora.

### Agentic RAG

The model (or app) decides to search, reformulate queries, or fetch more rounds. Production apps often keep **app-forced search** for scoped chats so behavior stays predictable on small on-device models.

### Late interaction and better embeddings

ColBERT-style late interaction and stronger multilingual embedding models improved recall on short queries. On-device stacks increasingly use Apple NLEmbedding or small open embedders instead of cloud APIs.

### Multimodal RAG

Retrieve images, tables, and slide screenshots alongside text; VLMs then answer over mixed evidence.

### Long-context vs RAG

Million-token context windows reduced pressure for some desktop workflows, but RAG remains preferable for large private corpora, citations, cost, and mobile memory limits. Many systems combine moderate context with retrieval.

### On-device GenAI runtimes

Frameworks such as LiteRT-LM and MLX make small LLMs practical on phones. RAG on device typically means: local FTS + embeddings, scoped collections, then a compact model (e.g. sub‑3B) that follows grounding rules.

### Evaluation

RAG-specific evals measure retrieval recall, faithfulness (does the answer stick to sources?), and answer quality. Synthetic question generation from docs is common for regression tests.

### Privacy-preserving RAG

Local indexes, encrypted stores, and policies that never upload raw chunks. Enterprise vendors also offer VPC-only retrieval APIs; consumer apps emphasize fully offline paths.

## Design checklist for a product like Nook

1. Scope search to user-selected collections.
2. Hybrid retrieve; drop weak matches so general questions do not get fake citations.
3. Pass a short evidence block into the prompt with clear source labels.
4. Separate policies: document questions → ground strictly; general knowledge → answer normally if evidence is unrelated.
5. Show a search tool chip for transparency; show citation pills only for grounded answers.
6. Re-index when files are added, updated, or deleted.

## Short glossary

- **Chunk**: A passage stored and retrieved as one unit.
- **Embedding**: Vector representation of text for similarity search.
- **FTS**: Full-text (keyword) search.
- **Grounding**: Constraining the model to provided evidence.
- **Top‑k**: Number of passages returned to the generator.
- **Reranker**: Second-stage model that reorders candidates.
- **Hybrid search**: Combining lexical and dense scores.

## Summary

RAG lets language models answer with your documents instead of only training memory. It is the backbone of modern knowledge chat, support bots, and private on-device assistants. The frontier is less “whether to use RAG” and more **reliable retrieval, honest citations, hybrid indexes, and small models that obey grounding rules**—especially when inference runs fully on the user’s device.

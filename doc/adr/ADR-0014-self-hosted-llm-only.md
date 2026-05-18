# Architecture Decision Record (ADR)

## Title
ADR-0014: Chat surface always uses a self-hosted, OpenAI-compatible LLM endpoint

## Status
Accepted — 2026-05-18 — Owner: Brandt Frazier

Supersedes the Anthropic-API portion of [ADR-0012](ADR-0012-phoenix-liveview-chat-surface.md).

## Context
ADR-0012 set the chat surface as Phoenix LiveView talking directly to the Anthropic API (Claude). That decision was made for the prototype's velocity — Claude was familiar, tool-use was reliable, and we wanted to move.

On reflection, motif's product commitment requires more than that. **The product will always run against a self-hosted model**, never a SaaS inference provider. Reasons (any one would be sufficient):

- **Cost.** Game sessions are LLM-heavy by design; tabletop RPGs can run hours. Per-token SaaS pricing is the wrong cost shape.
- **Privacy.** Sessions contain users' private hands (Clue), their characters' actions, and eventually their roleplay text in any larger game. Sending that to a third party isn't acceptable.
- **Latency and availability.** The product must work without an internet connection to a vendor and without that vendor's rate limits or outages.
- **Vendor independence.** Locking the engine's correctness to a single provider's quirks (response format, tool-call grammar, caching primitives, model lineup) creates a long-term liability.

This isn't a "use whichever is cheapest" preference. It's a load-bearing product invariant.

## Decision
The chat surface (`motif_web`) speaks the **OpenAI-compatible Chat Completions API** (`POST /v1/chat/completions`) to a configurable base URL. The default development target is **LM Studio** on `http://127.0.0.1:1234/v1`; production targets will be **vLLM** or **llama.cpp's server**, both of which speak the same wire format.

Concretely:

- The LLM client module is `MotifWeb.LLM` (vendor-neutral name). Its transport is HTTP via `req`.
- Configuration:
  - `LLM_BASE_URL` (env) → `:motif_web, :llm_base_url`. Default: `http://127.0.0.1:1234/v1`.
  - `LLM_MODEL` (env) → `:motif_web, :llm_model`. Default: a placeholder name; the user's loaded model id has to match.
  - `LLM_API_KEY` (env, optional) → `:motif_web, :llm_api_key`. Default: `nil`. Most self-hosted servers accept any string or none; the field exists so a deployment can put a gateway in front.
- No Anthropic SDK. No `cache_control`. No content-block message format. No Claude-specific fields.
- Tool catalogs are translated from MCP's `inputSchema` shape (camelCase, from ADR-0013) into OpenAI's `{type: "function", function: {name, description, parameters}}` shape at the wire boundary.
- The LiveView's tool-use loop stays the same in shape (Anthropic-flavored internal blocks) only because the translation lives inside `MotifWeb.LLM`; the LiveView is agnostic.

## Rationale
- **OpenAI Chat Completions is the lingua franca** of self-hosted inference servers. LM Studio, vLLM, llama.cpp's server, Ollama, TGI, text-generation-webui — they all implement it. Coding to it gives us portability across the entire self-hosted stack without changing anything but the base URL.
- **No SaaS dependency** means no API keys to leak, no per-token billing, no rate-limit cliffs, no model-deprecation churn. A user can run motif fully offline.
- **Future-proof against frontier model lineup changes.** When OSS models improve, swapping is `LLM_MODEL=<newer>`; no code change.

**Alternatives considered:**
- **Keep Anthropic as the default; LM Studio as an option.** Rejected: a SaaS dependency lurking as the "default" means the product would silently rot toward "needs an API key to work." Defaults shape what gets tested and what gets demoed.
- **Multi-backend abstraction (Anthropic + OpenAI shape + something else).** Premature; the product commitment is one direction. Add a backend only when we have a real reason to.
- **Speak Anthropic's wire format but proxy through a translator (LiteLLM, OpenRouter, etc.).** Adds a moving part to demonstrate the same outcome. Not worth it.
- **Build a richer abstraction (e.g. our own "LLM Provider" behaviour with multiple impls).** Will earn it only if a second provider arrives. Today: one impl.

## Consequences
**Positive**
- The deployable artifact has no required outbound dependency for inference.
- Tool-call behavior gets exercised against the same model family in dev and prod (whichever OSS model the user runs); no surprises from a frontier-model dev environment.
- We avoid premature commitment to any one OSS server — LM Studio for dev, vLLM/llama.cpp for prod is fine, but so is anything else that implements the spec.

**Negative**
- Tool-call quality is **model-dependent**. Smaller models (7B–13B) often malform JSON in `tool_calls.function.arguments` or hallucinate tool names. Mitigation: the prototype targets 30B+ tool-trained models (e.g. Qwen 2.5 32B+). Build with graceful degradation in mind, not frontier-only flows.
- Anthropic-specific features we will not get: prompt caching (their flavor), structured "thinking" blocks, citations. Mitigation: design game flow so these aren't required.
- The user is responsible for running the inference server. We document the LM Studio dev path; we don't host inference for them.

**Future considerations**
- If the product later wants a remote-but-self-hosted control plane (player has their own server, motif connects out), the base-URL configuration already supports it.
- If multiple OSS servers exhibit subtle wire incompatibilities, we may need a thin compatibility layer per server. Track per-server; only add when actually broken.

## References
- ADR-0012 (Phoenix LiveView chat surface) — superseded for its Anthropic API portion; LiveView remains.
- ADR-0001 (architectural boundaries) — unchanged; this ADR replaces the LLM behind the boundary.
- ADR-0013 (homegrown MCP adapter) — the MCP tool catalog format is translated to OpenAI's `tools` shape at the wire boundary in `MotifWeb.LLM`.
- OpenAI Chat Completions: https://platform.openai.com/docs/api-reference/chat
- LM Studio local server: https://lmstudio.ai/docs/local-server
- vLLM OpenAI-compatible server: https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html
- llama.cpp server: https://github.com/ggerganov/llama.cpp/tree/master/examples/server

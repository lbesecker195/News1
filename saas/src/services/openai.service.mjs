import { env } from "../config/env.mjs";

const TIMEOUT_MS = 60_000;
const MAX_RETRIES = 4;

/*
 * Chat Completions with a forced JSON object response, matching the pattern
 * already used by hugo/src/openai.mjs. Retries only on the errors that are
 * actually transient; everything else fails fast so the caller sees it.
 */
export async function aiJSON(instruction, input, {
  model = env.openaiModel,
  timeoutMs = TIMEOUT_MS,
  maxRetries = MAX_RETRIES
} = {}) {
  if (!env.openaiApiKey) {
    throw new Error("OPENAI_API_KEY is required");
  }

  /*
   * The API refuses response_format: json_object unless the word "json"
   * appears somewhere in the messages. Every prompt here already asks for a
   * JSON shape — {"stories":[…]} — but shows it rather than naming it, which
   * the check does not accept. Appended centrally so no individual prompt has
   * to remember, and harmless when one already says it.
   */
  const messages = [
    { role: "system", content: `${instruction}\n\nRespond with JSON only.` },
    {
      role: "user",
      content: typeof input === "string" ? input : JSON.stringify(input)
    }
  ];

  let lastError;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const response = await fetch(
        "https://api.openai.com/v1/chat/completions",
        {
          method: "POST",
          signal: controller.signal,
          headers: {
            authorization: `Bearer ${env.openaiApiKey}`,
            "content-type": "application/json"
          },
          body: JSON.stringify({
            model,
            response_format: { type: "json_object" },
            messages
          })
        }
      );

      const text = await response.text();

      if (response.status === 429 || response.status >= 500) {
        lastError = new Error(`OpenAI ${response.status}: ${snippet(text)}`);

        if (attempt === maxRetries) throw lastError;

        await sleep(backoffMs(attempt));
        continue;
      }

      if (!response.ok) {
        throw new Error(`OpenAI ${response.status}: ${snippet(text)}`);
      }

      const content = JSON.parse(text)?.choices?.[0]?.message?.content;

      if (typeof content !== "string" || !content.trim()) {
        throw new Error("OpenAI returned an empty completion");
      }

      return JSON.parse(stripFences(content));
    } catch (error) {
      lastError = error;

      const retryable =
        error.name === "AbortError" ||
        error.code === "ECONNRESET" ||
        error.code === "ETIMEDOUT" ||
        /^OpenAI (429|5)/.test(error.message ?? "");

      if (!retryable || attempt === maxRetries) throw error;

      await sleep(backoffMs(attempt));
    } finally {
      clearTimeout(timer);
    }
  }

  throw lastError;
}

function backoffMs(attempt) {
  return Math.min(16_000, 500 * 2 ** attempt) +
    Math.floor(Math.random() * 250);
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const stripFences = value =>
  value.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();

const snippet = value =>
  String(value).replace(/\s+/g, " ").slice(0, 240);

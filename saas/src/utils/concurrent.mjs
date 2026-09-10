/*
 * Run an async function over a list, a few at a time.
 *
 * Translating an article into eleven languages took eleven round trips in
 * series — around eight minutes an article, and most of that spent waiting.
 * The calls are independent, so they need not be sequential; what they must
 * not be is unbounded, because eleven simultaneous requests per article across
 * twelve sections is how an account meets its rate limit.
 *
 * Results come back in the order they were given, whatever order they finish
 * in, so callers can pair them with their inputs.
 */
export async function mapConcurrent(items, limit, fn) {
  const list = [...items];
  const results = new Array(list.length);

  if (!list.length) return results;

  const workers = Math.max(1, Math.min(limit, list.length));

  let next = 0;

  async function run() {
    while (true) {
      const index = next++;

      if (index >= list.length) return;

      results[index] = await fn(list[index], index);
    }
  }

  /*
   * A worker that throws would leave the rest unresolved, so failures are the
   * caller's to handle inside fn — every caller here already returns null for
   * a failed item rather than throwing.
   */
  await Promise.all(Array.from({ length: workers }, run));

  return results;
}

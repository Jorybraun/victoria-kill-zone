// String-aware comment stripper for JSON-with-comments files (wrangler.jsonc).
// Walks the source tracking string state; drops `//...\n` and `/*...*/` only
// outside strings so comment-like sequences inside string values survive.
export function stripJsonComments(source) {
  let out = '';
  let i = 0;
  let inString = false;
  while (i < source.length) {
    const char = source[i];
    if (inString) {
      out += char;
      if (char === '\\') {
        out += source[i + 1] ?? '';
        i += 2;
        continue;
      }
      if (char === '"') inString = false;
      i += 1;
      continue;
    }
    if (char === '"') {
      inString = true;
      out += char;
      i += 1;
      continue;
    }
    if (char === '/' && source[i + 1] === '/') {
      while (i < source.length && source[i] !== '\n') i += 1;
      continue;
    }
    if (char === '/' && source[i + 1] === '*') {
      i += 2;
      while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) i += 1;
      i += 2;
      continue;
    }
    out += char;
    i += 1;
  }
  return out;
}

export function parseJsonc(source) {
  return JSON.parse(stripJsonComments(source));
}

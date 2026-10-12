/** Prefix absolute site paths with Astro `base` (e.g. `/ai-usage-web/` on subpath hosting). */
export function withBase(path = '') {
  const raw = import.meta.env.BASE_URL || '/';
  const base = raw.endsWith('/') ? raw : `${raw}/`;
  const normalized = path.replace(/^\/+/, '');
  if (!normalized) return base;
  return `${base}${normalized}`;
}

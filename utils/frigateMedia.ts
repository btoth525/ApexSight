export function apiImageUrl(baseUrl: string, path: string, params?: Record<string, string | number | boolean>): string {
  return apiMediaUrl(baseUrl, path, { ...(params ?? {}), _: Date.now() });
}

export function apiMediaUrl(baseUrl: string, path: string, params?: Record<string, string | number | boolean>): string {
  const base = baseUrl.replace(/\/+$/, "");
  const cleanPath = path.replace(/^\/+/, "");
  const search = new URLSearchParams();

  for (const [key, value] of Object.entries(params ?? {})) {
    search.set(key, String(value));
  }

  const query = search.toString();
  return `${base}/api/${cleanPath}${query ? `?${query}` : ""}`;
}

export function mediaHeaders(token: string | null): Record<string, string> | undefined {
  if (!token || token === "session") return undefined;
  return { Cookie: `frigate_token=${token}` };
}

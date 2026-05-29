let _url: string | null = null;

export const pendingDeeplink = {
  set(url: string) { _url = url; },
  consume(): string | null { const u = _url; _url = null; return u; },
};

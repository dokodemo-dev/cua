// Small DOM helpers. Everything user-visible goes through textContent or a
// fixed icon set, so a prompt or an agent's answer can never inject markup.

type Child = Node | string | number | null | undefined | false;

export interface Attrs {
  class?: string;
  text?: string;
  html?: string;
  dataset?: Record<string, string>;
  [key: string]: unknown;
}

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Attrs = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') node.className = String(value);
    else if (key === 'text') node.textContent = String(value);
    else if (key === 'html') node.innerHTML = String(value);
    else if (key === 'dataset') {
      for (const [name, item] of Object.entries(value as Record<string, string>)) {
        node.dataset[name] = item;
      }
    } else if (key.startsWith('on') && typeof value === 'function') {
      node.addEventListener(key.slice(2).toLowerCase(), value as EventListener);
    } else if (typeof value === 'boolean') {
      (node as unknown as Record<string, unknown>)[key] = value;
    } else if (key in node) {
      (node as unknown as Record<string, unknown>)[key] = value;
    } else {
      node.setAttribute(key, String(value));
    }
  }
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    node.append(typeof child === 'number' ? String(child) : child);
  }
  return node;
}

export function clear(node: Element): void {
  node.replaceChildren();
}

export function escapeHtml(value: unknown): string {
  return String(value ?? '').replace(/[&<>"']/g, (character) => {
    switch (character) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&#39;';
    }
  });
}

export type IconName =
  | 'search'
  | 'menu'
  | 'plus'
  | 'send'
  | 'copy'
  | 'retry'
  | 'more'
  | 'close'
  | 'chevron'
  | 'settings'
  | 'logout'
  | 'monitor'
  | 'library'
  | 'info'
  | 'check'
  | 'external'
  | 'archive'
  | 'file'
  | 'pin'
  | 'palette'
  | 'trash'
  | 'key'
  | 'arrow-left';

const ICON_PATHS: Record<IconName, string> = {
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14Zm5.5 12.5L21 21',
  menu: 'M4 7h16M4 12h16M4 17h16',
  plus: 'M12 5v14M5 12h14',
  send: 'M12 19V5m0 0-6 6m6-6 6 6',
  copy: 'M9 9h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2Zm-3 6H5a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1',
  retry: 'M20 11a8 8 0 1 0-2.3 6.3M20 5v6h-6',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  close: 'M6 6l12 12M18 6 6 18',
  chevron: 'm6 9 6 6 6-6',
  settings:
    'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.4-3a7.4 7.4 0 0 0-.1-1.1l2-1.6-2-3.4-2.4 1a7.5 7.5 0 0 0-1.9-1.1L14.6 3H9.4L9 5.8a7.5 7.5 0 0 0-1.9 1.1l-2.4-1-2 3.4 2 1.6a7.4 7.4 0 0 0 0 2.2l-2 1.6 2 3.4 2.4-1a7.5 7.5 0 0 0 1.9 1.1l.4 2.8h5.2l.4-2.8a7.5 7.5 0 0 0 1.9-1.1l2.4 1 2-3.4-2-1.6c.1-.4.1-.8.1-1.1Z',
  logout: 'M15 17l5-5-5-5M20 12H9m3 9H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h7',
  monitor: 'M4 4h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1Zm5 16h6m-3-4v4',
  library: 'M4 5a2 2 0 0 1 2-2h4v18H6a2 2 0 0 1-2-2V5Zm8-2h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4V3Z',
  info: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Zm0-6v-5m0-3h.01',
  check: 'm5 13 4 4L19 7',
  external: 'M14 4h6v6m0-6L10 14M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5',
  archive: 'M3 5h18v4H3V5Zm2 4v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9M10 13h4',
  file: 'M6 3h7l5 5v13H6V3Zm7 0v5h5',
  pin: 'M12 17v5M9 10.8V4h6v6.8l2 2.2v2H7v-2l2-2.2Z',
  palette:
    'M12 21a9 9 0 1 1 0-18c4.5 0 8 3 8 6.5 0 2.5-2 4.5-4.5 4.5H13a2 2 0 0 0-1.6 3.2c.4.5.6 1 .6 1.3 0 1.5-.9 2.5-2 2.5Z',
  trash: 'M4 7h16M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2m-8 0 1 13h8l1-13',
  key: 'M15 7a4 4 0 1 1-3.5 6H9v3H6v-3H4v-3h7.5A4 4 0 0 1 15 7Zm2 0h.01',
  'arrow-left': 'M19 12H5m0 0 6 6m-6-6 6-6',
};

export function icon(name: IconName, size = 20): SVGSVGElement {
  const wrapper = document.createElement('span');
  wrapper.innerHTML =
    `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" ` +
    'stroke="currentColor" stroke-width="1.7" stroke-linecap="round" ' +
    `stroke-linejoin="round" aria-hidden="true"><path d="${ICON_PATHS[name]}"/></svg>`;
  return wrapper.firstElementChild as SVGSVGElement;
}

export function iconHtml(name: IconName, size = 20): string {
  return icon(name, size).outerHTML;
}

export function fmtInterval(seconds: number): string {
  if (!seconds) return '-';
  if (seconds % 86400 === 0) return `${seconds / 86400}日`;
  if (seconds % 3600 === 0) return `${seconds / 3600}時間`;
  if (seconds % 60 === 0) return `${seconds / 60}分`;
  return `${seconds}秒`;
}

export function fmtBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '-';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function fmtDateTime(unix: number): string {
  if (!unix) return '-';
  return new Date(unix * 1000).toLocaleString();
}

export function fmtRelative(unix: number): string {
  if (!unix) return '-';
  const diff = unix * 1000 - Date.now();
  const abs = Math.abs(diff);
  const minutes = Math.round(abs / 60_000);
  if (minutes < 1) return 'まもなく';
  if (minutes < 60) return diff > 0 ? `${minutes}分後` : `${minutes}分前`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return diff > 0 ? `${hours}時間後` : `${hours}時間前`;
  return fmtDateTime(unix);
}

let toastTimer = 0;

function hideToast(box: HTMLElement): void {
  if (typeof box.hidePopover === 'function' && box.matches(':popover-open')) {
    box.hidePopover();
    return;
  }
  box.hidden = true;
}

// Toasts live in the top layer (popover) so a failure raised from a modal is
// visible instead of being painted under the dialog's backdrop.
export function toast(message: string, tone: 'info' | 'error' = 'info'): void {
  const box = document.getElementById('toast');
  if (!box) return;
  box.textContent = message;
  box.dataset.tone = tone;
  box.hidden = false;
  if (typeof box.showPopover === 'function') {
    try {
      box.showPopover();
    } catch {
      // Already open, or the browser refuses while another popover is showing.
    }
  }
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => hideToast(box), 4200);
}

export async function copyText(value: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(value);
    return true;
  } catch {
    // Over plain HTTP (the VPN address) navigator.clipboard is undefined, and
    // over HTTP/2 Safari refuses it; execCommand still copies a selected field.
    const area = el('textarea', { class: 'offscreen', value, readonly: 'readonly' });
    document.body.append(area);
    area.focus();
    area.select();
    area.setSelectionRange(0, value.length);
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch {
      ok = false;
    }
    area.remove();
    return ok;
  }
}
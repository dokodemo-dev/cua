// A deliberately small Markdown renderer for agent answers.
//
// Agent output arrives as plain text, but it uses Markdown conventions for
// lists, code and links. Rendering it as text made every answer look like a
// terminal dump; this is enough structure to read like Grok Bot's answers
// without pulling a parser into the embedded bundle.
//
// Safety: text becomes text nodes, and links are limited to http(s).

import { el } from './dom';

const FENCE = /^\s*```(\S*)\s*$/;
const HEADING = /^(#{1,6})\s+(.*)$/;
const BULLET = /^\s*[-*+]\s+(.*)$/;
const ORDERED = /^\s*\d+[.)]\s+(.*)$/;
const QUOTE = /^\s*>\s?(.*)$/;
const RULE = /^\s*(?:---+|\*\*\*+)\s*$/;

function isBlockStart(line: string): boolean {
  return (
    FENCE.test(line) ||
    HEADING.test(line) ||
    BULLET.test(line) ||
    ORDERED.test(line) ||
    QUOTE.test(line) ||
    RULE.test(line)
  );
}

function trimLinkEnd(url: string): string {
  let end = url.length;
  while (end > 0) {
    const last = url[end - 1];
    if (
      last === '.' ||
      last === ',' ||
      last === ';' ||
      last === ':' ||
      last === '!' ||
      last === '?'
    ) {
      end -= 1;
      continue;
    }
    if (last === ')' && (url.slice(0, end).match(/\(/g) ?? []).length === 0) {
      end -= 1;
      continue;
    }
    break;
  }
  return url.slice(0, end);
}

function appendInline(parent: Element | DocumentFragment, text: string, allowLinks = true): void {
  const pattern = allowLinks
    ? /`([^`\n]+)`|\*\*([^*\n]+)\*\*|~~([^~\n]+)~~|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>]+)/g
    : /`([^`\n]+)`|\*\*([^*\n]+)\*\*|~~([^~\n]+)~~/g;
  let last = 0;
  for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
    if (match.index > last) parent.append(document.createTextNode(text.slice(last, match.index)));
    const [whole, code, bold, strike, label, href, raw] = match;
    if (code !== undefined) {
      parent.append(el('code', { class: 'inlineCode', text: code }));
    } else if (bold !== undefined) {
      parent.append(el('strong', { text: bold }));
    } else if (strike !== undefined) {
      parent.append(el('del', { text: strike }));
    } else if (label !== undefined && href !== undefined) {
      const anchor = el('a', { href, target: '_blank', rel: 'noopener noreferrer' });
      appendInline(anchor, label, false);
      parent.append(anchor);
    } else if (raw !== undefined) {
      const url = trimLinkEnd(raw);
      parent.append(
        el('a', { href: url, target: '_blank', rel: 'noopener noreferrer', text: url })
      );
      if (url !== raw) parent.append(document.createTextNode(raw.slice(url.length)));
    }
    last = match.index + whole.length;
  }
  if (last < text.length) parent.append(document.createTextNode(text.slice(last)));
}

function paragraph(lines: string[]): HTMLElement {
  const node = el('p');
  lines.forEach((line, index) => {
    if (index > 0) node.append(el('br'));
    appendInline(node, line);
  });
  return node;
}

function codeBlock(lines: string[], language: string): HTMLElement {
  const code = el('code', { text: lines.join('\n') });
  if (language) code.classList.add(`language-${language}`);
  const pre = el('pre', {}, code);
  return el(
    'div',
    { class: 'codeBlock' },
    el(
      'div',
      { class: 'codeHead' },
      el('span', { class: 'codeLang', text: language || 'text' }),
      el('button', {
        class: 'codeCopy',
        type: 'button',
        'data-copy-code': '1',
        text: 'コピー',
      })
    ),
    pre
  );
}

export function renderMarkdown(source: string): DocumentFragment {
  const fragment = document.createDocumentFragment();
  const lines = source.replace(/\r\n?/g, '\n').split('\n');
  let index = 0;

  while (index < lines.length) {
    const line = lines[index] ?? '';
    if (line.trim() === '') {
      index += 1;
      continue;
    }

    const fence = FENCE.exec(line);
    if (fence) {
      const language = fence[1] ?? '';
      const body: string[] = [];
      index += 1;
      while (index < lines.length && !FENCE.test(lines[index] ?? '')) {
        body.push(lines[index] ?? '');
        index += 1;
      }
      index += 1;
      fragment.append(codeBlock(body, language));
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      const level = Math.min(6, heading[1]?.length ?? 1);
      const node = el(`h${level}` as 'h1');
      appendInline(node, heading[2] ?? '');
      fragment.append(node);
      index += 1;
      continue;
    }

    if (RULE.test(line)) {
      fragment.append(el('hr'));
      index += 1;
      continue;
    }

    const quote = QUOTE.exec(line);
    if (quote) {
      const body: string[] = [];
      while (index < lines.length) {
        const next = QUOTE.exec(lines[index] ?? '');
        if (!next) break;
        body.push(next[1] ?? '');
        index += 1;
      }
      const block = el('blockquote');
      for (const item of body) {
        block.append(paragraph([item]));
      }
      fragment.append(block);
      continue;
    }

    if (BULLET.test(line) || ORDERED.test(line)) {
      const ordered = ORDERED.test(line);
      const list = el(ordered ? 'ol' : 'ul');
      while (index < lines.length) {
        const current = lines[index] ?? '';
        const match = ordered ? ORDERED.exec(current) : BULLET.exec(current);
        if (!match) break;
        const item = el('li');
        appendInline(item, match[1] ?? '');
        list.append(item);
        index += 1;
      }
      fragment.append(list);
      continue;
    }

    const body: string[] = [];
    while (index < lines.length) {
      const current = lines[index] ?? '';
      if (current.trim() === '') break;
      if (body.length > 0 && isBlockStart(current)) break;
      body.push(current);
      index += 1;
    }
    fragment.append(paragraph(body));
  }

  return fragment;
}
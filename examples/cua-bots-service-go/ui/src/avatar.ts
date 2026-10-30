// The koala face, ported from the Mac app's BotAvatar so both show the same
// bot. Grok Bot's look is a rounded blob; Cua keeps its own koala, with the
// same colour and expression vocabulary.

import type { Avatar, ColorName, EarStyle, EyeStyle } from './api';
import { escapeHtml } from './dom';

const KOALA = {
  head: 'M0.2216 0.8572C0.3254 0.8460 0.4282 0.8329 0.5279 0.7991C0.6277 0.7654 0.7386 0.7173 0.8201 0.6548C0.9016 0.5923 0.9719 0.5134 1.0168 0.4239C1.0618 0.3344 1.0870 0.2218 1.0896 0.1176C1.0923 0.0134 1.0666 -0.1023 1.0328 -0.2012C0.9990 -0.3002 0.9479 -0.3917 0.8870 -0.4761C0.8261 -0.5605 0.7477 -0.6423 0.6673 -0.7076C0.5869 -0.7729 0.5002 -0.8271 0.4047 -0.8679C0.3091 -0.9087 0.1992 -0.9414 0.0939 -0.9521C-0.0114 -0.9629 -0.1260 -0.9552 -0.2272 -0.9324C-0.3284 -0.9097 -0.4242 -0.8684 -0.5133 -0.8154C-0.6024 -0.7624 -0.6901 -0.6891 -0.7619 -0.6143C-0.8336 -0.5395 -0.8938 -0.4580 -0.9438 -0.3664C-0.9939 -0.2748 -1.0400 -0.1685 -1.0621 -0.0646C-1.0841 0.0394 -1.0930 0.1575 -1.0760 0.2575C-1.0589 0.3575 -1.0200 0.4555 -0.9597 0.5354C-0.8995 0.6153 -0.8051 0.6869 -0.7144 0.7367C-0.6236 0.7865 -0.5183 0.8126 -0.4150 0.8342C-0.3117 0.8559 -0.2009 0.8627 -0.0948 0.8666C0.0113 0.8704 0.1178 0.8685 0.2216 0.8572Z',
  ear: 'M-0.4380 0.4512C-0.4425 0.4275 -0.4057 0.3372 -0.4029 0.2892C-0.4001 0.2412 -0.4179 0.2039 -0.4213 0.1633C-0.4246 0.1227 -0.4252 0.0832 -0.4229 0.0456C-0.4207 0.0081 -0.4156 -0.0281 -0.4077 -0.0620C-0.3999 -0.0960 -0.3891 -0.1282 -0.3758 -0.1580C-0.3625 -0.1878 -0.3464 -0.2156 -0.3279 -0.2408C-0.3094 -0.2660 -0.2882 -0.2889 -0.2650 -0.3091C-0.2417 -0.3293 -0.2159 -0.3470 -0.1885 -0.3618C-0.1610 -0.3765 -0.1312 -0.3887 -0.1002 -0.3979C-0.0692 -0.4070 -0.0362 -0.4134 -0.0024 -0.4167C0.0313 -0.4200 0.0668 -0.4204 0.1023 -0.4177C0.1379 -0.4150 0.1747 -0.4092 0.2110 -0.4004C0.2473 -0.3916 0.2908 -0.3753 0.3202 -0.3648C0.3496 -0.3543 0.3712 -0.3463 0.3875 -0.3375C0.4039 -0.3286 0.4095 -0.3209 0.4182 -0.3115C0.4270 -0.3022 0.4342 -0.2918 0.4401 -0.2812C0.4459 -0.2706 0.4504 -0.2594 0.4533 -0.2480C0.4562 -0.2367 0.4577 -0.2249 0.4577 -0.2133C0.4576 -0.2017 0.4561 -0.1898 0.4531 -0.1783C0.4501 -0.1668 0.4459 -0.1552 0.4395 -0.1442C0.4332 -0.1333 0.4183 -0.1231 0.4151 -0.1125C0.4119 -0.1018 0.4172 -0.0914 0.4205 -0.0804C0.4237 -0.0693 0.4316 -0.0575 0.4347 -0.0460C0.4378 -0.0346 0.4391 -0.0229 0.4391 -0.0117C0.4391 -0.0004 0.4376 0.0108 0.4346 0.0215C0.4317 0.0322 0.4273 0.0427 0.4215 0.0524C0.4157 0.0621 0.4087 0.0715 0.4001 0.0800C0.3915 0.0884 0.3776 0.0945 0.3700 0.1029C0.3623 0.1114 0.3565 0.1200 0.3542 0.1309C0.3520 0.1417 0.3573 0.1562 0.3565 0.1680C0.3557 0.1797 0.3531 0.1910 0.3493 0.2016C0.3456 0.2121 0.3404 0.2221 0.3340 0.2311C0.3276 0.2401 0.3198 0.2485 0.3110 0.2558C0.3021 0.2630 0.2919 0.2695 0.2807 0.2747C0.2694 0.2800 0.2501 0.2785 0.2435 0.2872C0.2369 0.2959 0.2439 0.3150 0.2412 0.3268C0.2385 0.3386 0.2333 0.3489 0.2272 0.3581C0.2211 0.3673 0.2135 0.3755 0.2046 0.3821C0.1958 0.3887 0.1861 0.3948 0.1741 0.3979C0.1622 0.4011 0.1387 0.3989 0.1329 0.4011C0.1271 0.4032 0.1489 0.4109 0.1393 0.4107C0.1297 0.4105 0.0966 0.4027 0.0752 0.3997C0.0537 0.3967 0.0321 0.3943 0.0105 0.3925C-0.0111 0.3908 -0.0329 0.3897 -0.0545 0.3893C-0.0762 0.3889 -0.0979 0.3891 -0.1196 0.3899C-0.1413 0.3908 -0.1630 0.3923 -0.1845 0.3945C-0.2061 0.3967 -0.2277 0.3995 -0.2491 0.4029C-0.2705 0.4064 -0.2918 0.4105 -0.3130 0.4152C-0.3342 0.4200 -0.3552 0.4253 -0.3761 0.4313C-0.3969 0.4373 -0.4336 0.4749 -0.4380 0.4512Z',
  earAt: { x: 0.9023, y: -0.4916 },
  nose: 'M0.23296 0.42779 C0.19057 0.46486 0.13275 0.48043 0.07633 0.48521 C0.02310 0.48973 -0.02903 0.48893 -0.08195 0.48281 C-0.14414 0.47564 -0.20747 0.45523 -0.24825 0.40734 C-0.26455 0.38820 -0.27439 0.36660 -0.27688 0.34165 C-0.27937 0.31670 -0.27812 0.29295 -0.27349 0.26758 C-0.25603 0.17211 -0.22610 0.08040 -0.18333 -0.00704 C-0.15783 -0.05918 -0.12021 -0.10971 -0.06567 -0.13415 C-0.01019 -0.15902 0.05222 -0.15085 0.09856 -0.11253 C0.11725 -0.09708 0.13279 -0.07983 0.14626 -0.05964 C0.16023 -0.03871 0.17253 -0.01777 0.18263 0.00543 L0.23245 0.11996 C0.25548 0.17287 0.28518 0.27454 0.28114 0.33176 C0.27848 0.36935 0.26162 0.40272 0.23295 0.42779 H0.23296 Z',
  leftEye: { x: -0.53029, y: -0.04019, squash: 0.94409 },
  rightEye: { x: 0.5351, y: -0.04055, squash: 0.94409 },
} as const;

const PALETTE: Record<ColorName, { face: string; nose: string; eye: string }> = {
  cloud: { face: '#E3E7EC', nose: '#7D8793', eye: '#0B0E13' },
  violet: { face: '#8B5CF6', nose: '#5B2FC9', eye: '#0B0E13' },
  orange: { face: '#FF7A2F', nose: '#C24E10', eye: '#0B0E13' },
  sky: { face: '#61BCFF', nose: '#2A7FC4', eye: '#0B0E13' },
  graphite: { face: '#262A31', nose: '#4B525E', eye: '#F3F6FA' },
  slate: { face: '#8E98A3', nose: '#5B6571', eye: '#0B0E13' },
};

export const ACCENT: Record<ColorName, string> = {
  cloud: '#61BCFF',
  graphite: '#8E98A3',
  violet: '#8B5CF6',
  orange: '#FF7A2F',
  sky: '#61BCFF',
  slate: '#8E98A3',
};

type Glyph = '*' | 'o' | '-' | '^' | '+' | 'x' | '>' | '<' | '/' | '\\';

const EYE_STYLES: Record<EyeStyle, [Glyph, Glyph]> = {
  star: ['*', '*'],
  round: ['o', 'o'],
  happy: ['^', '^'],
  calm: ['-', '-'],
  plus: ['+', '+'],
  delight: ['>', '<'],
};

interface GlyphSpec {
  kind: 'lines' | 'poly' | 'ellipse';
  segs?: readonly (readonly [number, number, number, number])[];
  pts?: readonly (readonly [number, number])[];
  width: number;
  rotate: number;
  scale: number;
}

const GLYPHS: Record<Glyph, GlyphSpec> = {
  '*': {
    kind: 'lines',
    segs: [
      [-0.17, 0, 0.17, 0],
      [-0.085, -0.147, 0.085, 0.147],
      [0.085, -0.147, -0.085, 0.147],
    ],
    width: 0.066,
    rotate: 0,
    scale: 1.1,
  },
  o: { kind: 'ellipse', width: 0.085, rotate: -12, scale: 1.2 },
  '-': { kind: 'lines', segs: [[-0.225, 0, 0.225, 0]], width: 0.075, rotate: 0, scale: 1.15 },
  '^': {
    kind: 'poly',
    pts: [
      [-0.17, 0.2],
      [0, -0.2],
      [0.17, 0.2],
    ],
    width: 0.08,
    rotate: 0,
    scale: 1.1,
  },
  '+': {
    kind: 'lines',
    segs: [
      [-0.22, 0, 0.22, 0],
      [0, -0.22, 0, 0.22],
    ],
    width: 0.085,
    rotate: 0,
    scale: 1.1,
  },
  x: {
    kind: 'lines',
    segs: [
      [-0.22, 0, 0.22, 0],
      [0, -0.22, 0, 0.22],
    ],
    width: 0.085,
    rotate: 45,
    scale: 1.1,
  },
  '>': {
    kind: 'poly',
    pts: [
      [-0.17, -0.17],
      [0.17, 0],
      [-0.17, 0.17],
    ],
    width: 0.075,
    rotate: 0,
    scale: 1.1,
  },
  '<': {
    kind: 'poly',
    pts: [
      [0.17, -0.17],
      [-0.17, 0],
      [0.17, 0.17],
    ],
    width: 0.075,
    rotate: 0,
    scale: 1.1,
  },
  '/': { kind: 'lines', segs: [[-0.11, 0.21, 0.11, -0.21]], width: 0.08, rotate: 0, scale: 1.1 },
  '\\': { kind: 'lines', segs: [[-0.11, -0.21, 0.11, 0.21]], width: 0.08, rotate: 0, scale: 1.1 },
};

export type Mood =
  | 'idle'
  | 'thinking'
  | 'working'
  | 'needsApproval'
  | 'done'
  | 'happy'
  | 'paused'
  | 'error';

function moodEyes(mood: Mood, style: EyeStyle, t: number): [Glyph, Glyph] {
  const pair = EYE_STYLES[style] ?? EYE_STYLES.star;
  switch (mood) {
    case 'thinking':
      return t % 1.6 < 0.8 ? ['/', '/'] : ['\\', '\\'];
    case 'working':
      return ['+', '+'];
    case 'needsApproval':
      return ['o', 'o'];
    case 'done':
    case 'happy':
      return ['^', '^'];
    case 'paused':
      return ['-', '-'];
    case 'error':
      return ['x', 'x'];
    default:
      return pair;
  }
}

let clipID = 0;

function eyeMark(
  glyph: Glyph,
  eye: { x: number; y: number; squash: number },
  color: string,
  spin: number
): string {
  const glyphSpec = GLYPHS[glyph] ?? GLYPHS['*'];
  const rotate = (glyph === '+' ? spin : 0) + glyphSpec.rotate;
  const transform =
    `translate(${eye.x} ${eye.y}) rotate(${rotate}) ` +
    `scale(${(glyphSpec.scale * eye.squash).toFixed(4)} ${glyphSpec.scale})`;
  const stroke = `fill="none" stroke="${color}" stroke-width="${glyphSpec.width}" stroke-linecap="butt"`;
  if (glyphSpec.kind === 'ellipse') {
    return `<ellipse transform="${transform}" cx="0" cy="0" rx="0.165" ry="0.2" ${stroke}/>`;
  }
  const d =
    glyphSpec.kind === 'poly'
      ? 'M' + (glyphSpec.pts ?? []).map((point) => point.join(' ')).join('L')
      : (glyphSpec.segs ?? []).map((seg) => `M${seg[0]} ${seg[1]}L${seg[2]} ${seg[3]}`).join('');
  return `<path transform="${transform}" d="${d}" ${stroke}/>`;
}

export function koalaSvg(
  avatar: Avatar | undefined,
  mood: Mood = 'idle',
  t = 0,
  cls = 'avatar'
): SVGSVGElement {
  const wrapper = document.createElement('div');
  wrapper.innerHTML = koalaHtml(avatar, mood, t, cls);
  return wrapper.firstElementChild as SVGSVGElement;
}

export function koalaHtml(
  avatar: Avatar | undefined,
  mood: Mood = 'idle',
  t = 0,
  cls = 'avatar'
): string {
  const av: Avatar = avatar ?? { color: 'sky', eyes: 'star', ears: 'scalloped' };
  const palette = PALETTE[av.color] ?? PALETTE.sky;
  const ears: EarStyle = av.ears;
  const small = ears === 'small';
  const scale = small ? 0.72 : 1;
  const pull = small ? 0.86 : 1;
  const earMarks = [-1, 1]
    .map((side) => {
      if (ears === 'round') {
        return `<circle cx="${(side * KOALA.earAt.x * 0.97).toFixed(4)}" cy="${(KOALA.earAt.y * 1.02).toFixed(4)}" r="0.4363" fill="${palette.face}"/>`;
      }
      const transform =
        `translate(${(side * KOALA.earAt.x * pull).toFixed(4)} ${(KOALA.earAt.y * pull).toFixed(4)}) ` +
        `scale(${side * scale} ${scale})`;
      return `<path transform="${transform}" d="${KOALA.ear}" fill="${palette.face}"/>`;
    })
    .join('');
  const eyes = moodEyes(mood, av.eyes, t);
  const right = moodEyes(mood, av.eyes, t - 0.05)[1];
  const spin = mood === 'working' ? (t % 1.2 < 0.6 ? 15 : -15) : 0;
  const id = `koala${++clipID}`;
  const animate = mood === 'idle' ? '0' : '1';
  return (
    `<svg class="${cls}" viewBox="-1.425 -1.365 2.85 2.85" data-avatar="${escapeHtml(
      JSON.stringify(av)
    )}" data-mood="${mood}" data-anim="${animate}" aria-hidden="true">` +
    earMarks +
    `<path d="${KOALA.head}" fill="${palette.face}"/>` +
    `<clipPath id="${id}"><path d="${KOALA.head}"/></clipPath>` +
    `<g clip-path="url(#${id})"><path d="${KOALA.nose}" fill="${palette.nose}"/></g>` +
    eyeMark(eyes[0], KOALA.leftEye, palette.eye, spin) +
    eyeMark(right, KOALA.rightEye, palette.eye, spin) +
    '</svg>'
  );
}
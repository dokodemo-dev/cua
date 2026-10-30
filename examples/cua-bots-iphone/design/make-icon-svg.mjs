// Regenerates design/AppIcon.svg from the web UI's koala geometry.
// The rendered PNG (1024px) lives in App/Assets.xcassets; this file is the
// editable source so the icon and the in-app avatar cannot drift apart.
import { readFileSync, writeFileSync } from 'node:fs';

const avatarTs = process.argv[2];
const outfile = process.argv[3];
const ts = readFileSync(avatarTs, 'utf8');

function path(name) {
  const match = new RegExp(`${name}:\\s*'([^']+)'`).exec(ts);
  if (!match) throw new Error(`missing ${name}`);
  return match[1];
}

const head = path('head');
const ear = path('ear');
const nose = path('nose');

const svg = `<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2b3a58"/>
      <stop offset="0.52" stop-color="#182238"/>
      <stop offset="1" stop-color="#0a0f1a"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.44" r="0.52">
      <stop offset="0" stop-color="#61bcff" stop-opacity="0.34"/>
      <stop offset="0.62" stop-color="#61bcff" stop-opacity="0.10"/>
      <stop offset="1" stop-color="#61bcff" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="top" cx="0.5" cy="-0.1" r="0.85">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.18"/>
      <stop offset="0.55" stop-color="#ffffff" stop-opacity="0.03"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="ground" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#05080f" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#05080f" stop-opacity="0"/>
    </radialGradient>
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#050810" flood-opacity="0.40"/>
    </filter>
    <clipPath id="headClip"><path d="${head}"/></clipPath>
  </defs>

  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <rect width="1024" height="1024" fill="url(#top)"/>
  <ellipse cx="512" cy="812" rx="280" ry="56" fill="url(#ground)"/>

  <g filter="url(#soft)">
    <g transform="translate(512 500) scale(286)">
      <path transform="translate(-0.9023 -0.4916) scale(-1 1)" d="${ear}" fill="#E7ECF3"/>
      <path transform="translate(0.9023 -0.4916) scale(1 1)" d="${ear}" fill="#E7ECF3"/>
      <path d="${head}" fill="#E7ECF3"/>
      <g clip-path="url(#headClip)">
        <path d="${nose}" fill="#6F7B8C"/>
      </g>
      <g fill="none" stroke="#0B0E13" stroke-width="0.066" stroke-linecap="butt">
        <g transform="translate(-0.53029 -0.04019) rotate(0) scale(1.0385 1.1)">
          <path d="M-0.17 0L0.17 0M-0.085 -0.147L0.085 0.147M0.085 -0.147L-0.085 0.147"/>
        </g>
        <g transform="translate(0.5351 -0.04055) rotate(0) scale(1.0385 1.1)">
          <path d="M-0.17 0L0.17 0M-0.085 -0.147L0.085 0.147M0.085 -0.147L-0.085 0.147"/>
        </g>
      </g>
    </g>
  </g>
</svg>
`;

writeFileSync(outfile, svg);
console.log(`wrote ${outfile}`);

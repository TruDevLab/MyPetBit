// Три референса питомца. Каждый персонаж — функция (состояние) -> строка SVG 200x200.
// Подключается в index.html и в tools/export-svg.js (Node), поэтому без модулей и DOM.
(function (root) {
  'use strict';

  const STATES = ['idle', 'happy', 'sleep', 'work'];

  // Анимации общие для всех персонажей; встраиваются и в страницу, и в отдельные SVG.
  const CSS = `
.pet-body{animation:pet-float 3.2s ease-in-out infinite}
.pet-sleep .pet-body{animation:pet-breathe 4.8s ease-in-out infinite;transform-box:fill-box;transform-origin:50% 100%}
.pet-shadow{animation:pet-shadow 3.2s ease-in-out infinite;transform-box:fill-box;transform-origin:center}
.pet-sleep .pet-shadow{animation:none}
.pet-blink{animation:pet-blink 4.6s infinite;transform-box:fill-box;transform-origin:center}
.pet-pulse{animation:pet-pulse 1.4s ease-in-out infinite}
.pet-progress{animation:pet-progress 2.4s ease-in-out infinite;transform-box:fill-box;transform-origin:0 50%}
.pet-scan{animation:pet-scan 1.1s ease-in-out infinite alternate}
.pet-thrust{animation:pet-thrust .35s ease-in-out infinite alternate;transform-box:fill-box;transform-origin:center}
.pet-zz{animation:pet-zz 3s ease-in infinite;opacity:0}
.pet-zz.d2{animation-delay:1s}.pet-zz.d3{animation-delay:2s}
.pet-dot{animation:pet-pulse 1.2s ease-in-out infinite}
.pet-dot.d2{animation-delay:.2s}.pet-dot.d3{animation-delay:.4s}
@keyframes pet-float{0%,100%{transform:translateY(0)}50%{transform:translateY(-6px)}}
@keyframes pet-breathe{0%,100%{transform:scale(1,1)}50%{transform:scale(1.025,.975)}}
@keyframes pet-shadow{0%,100%{transform:scale(1)}50%{transform:scale(.86);opacity:.08}}
@keyframes pet-blink{0%,91%,97%,100%{transform:scaleY(1)}94%{transform:scaleY(.1)}}
@keyframes pet-pulse{0%,100%{opacity:1}50%{opacity:.35}}
@keyframes pet-progress{0%{transform:scaleX(.05)}80%,100%{transform:scaleX(1)}}
@keyframes pet-scan{from{transform:translateX(0)}to{transform:translateX(48px)}}
@keyframes pet-thrust{from{transform:scale(1);opacity:.55}to{transform:scale(.8,.7);opacity:.35}}
@keyframes pet-zz{0%{opacity:0;transform:translate(0,0)}20%{opacity:1}100%{opacity:0;transform:translate(10px,-22px)}}
@media (prefers-reduced-motion:reduce){.pet-body,.pet-shadow,.pet-blink,.pet-pulse,.pet-progress,.pet-scan,.pet-thrust,.pet-zz,.pet-dot{animation:none}.pet-zz{opacity:1}}
`;

  const shadow = (rx) =>
    `<ellipse class="pet-shadow" cx="100" cy="186" rx="${rx}" ry="6" fill="#000" opacity=".14"/>`;

  const zz = (x, y, color) => `
    <g font-family="-apple-system,Segoe UI,sans-serif" font-weight="700" fill="${color}">
      <text class="pet-zz" x="${x}" y="${y}" font-size="14">z</text>
      <text class="pet-zz d2" x="${x + 8}" y="${y - 6}" font-size="17">z</text>
      <text class="pet-zz d3" x="${x + 18}" y="${y - 12}" font-size="20">Z</text>
    </g>`;

  const wrap = (state, inner, defs = '') =>
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" class="pet pet-${state}">` +
    (defs ? `<defs>${defs}</defs>` : '') + inner + `</svg>`;

  // 1. Бит — маленький монитор с лицом на экране.
  function bit(state) {
    const C = '#5CF2E0';
    const faces = {
      idle: `
        <g class="pet-blink"><rect x="76" y="88" width="12" height="20" rx="6" fill="${C}"/>
        <rect x="112" y="88" width="12" height="20" rx="6" fill="${C}"/></g>
        <path d="M94 117 Q100 122 106 117" fill="none" stroke="${C}" stroke-width="3" stroke-linecap="round"/>`,
      happy: `
        <path d="M73 104 Q82 90 91 104 M109 104 Q118 90 127 104" fill="none" stroke="${C}" stroke-width="5" stroke-linecap="round"/>
        <path d="M91 113 Q100 127 109 113 Z" fill="${C}" stroke="${C}" stroke-width="2" stroke-linejoin="round"/>`,
      sleep: `
        <path d="M73 100 Q82 107 91 100 M109 100 Q118 107 127 100" fill="none" stroke="${C}" stroke-width="4" stroke-linecap="round" opacity=".7"/>
        <circle cx="100" cy="117" r="3" fill="none" stroke="${C}" stroke-width="2.5" opacity=".7"/>`,
      work: `
        <g class="pet-blink"><rect x="78" y="84" width="11" height="15" rx="5.5" fill="${C}"/>
        <rect x="111" y="84" width="11" height="15" rx="5.5" fill="${C}"/></g>
        <rect x="70" y="110" width="60" height="7" rx="3.5" fill="#2E3546"/>
        <rect class="pet-progress" x="70" y="110" width="60" height="7" rx="3.5" fill="${C}"/>`
    };
    const lamp = state === 'sleep' ? '#6B5A60' : '#FF7A6B';
    return wrap(state, `
      ${shadow(44)}
      <g class="pet-body">
        <line x1="100" y1="52" x2="100" y2="34" stroke="#C9CDD6" stroke-width="4" stroke-linecap="round"/>
        <circle cx="100" cy="30" r="12" fill="${lamp}" opacity="${state === 'sleep' ? 0 : 0.18}"/>
        <circle class="${state === 'work' ? 'pet-pulse' : ''}" cx="100" cy="30" r="6.5" fill="${lamp}"/>
        <rect x="64" y="146" width="24" height="16" rx="7" fill="#D5D9E1"/>
        <rect x="112" y="146" width="24" height="16" rx="7" fill="#D5D9E1"/>
        <rect x="32" y="86" width="12" height="30" rx="6" fill="#D5D9E1"/>
        <rect x="156" y="86" width="12" height="30" rx="6" fill="#D5D9E1"/>
        <rect x="40" y="50" width="120" height="104" rx="34" fill="#F4F5F7" stroke="#E2E5EB" stroke-width="2"/>
        <rect x="54" y="66" width="92" height="66" rx="22" fill="#1B1F2A"/>
        <path d="M64 76 Q70 70 80 70" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".12"/>
        ${faces[state]}
      </g>
      ${state === 'sleep' ? zz(132, 48, '#8A93A6') : ''}`);
  }

  // 2. Флу — светящаяся капля с кольцом-орбитой.
  function flu(state) {
    const INK = '#231C4A';
    const defs = `
      <radialGradient id="flu-body" cx="38%" cy="32%" r="75%">
        <stop offset="0" stop-color="#E6DEFF"/><stop offset=".5" stop-color="#A897FF"/><stop offset="1" stop-color="#6F5EF0"/>
      </radialGradient>
      <radialGradient id="flu-glow" cx="50%" cy="50%" r="50%">
        <stop offset="0" stop-color="#A897FF" stop-opacity=".45"/><stop offset="1" stop-color="#A897FF" stop-opacity="0"/>
      </radialGradient>
      <clipPath id="flu-front" clipPathUnits="userSpaceOnUse"><rect x="0" y="112" width="200" height="88"/></clipPath>`;
    const eye = (cx, cy) =>
      `<circle cx="${cx}" cy="${cy}" r="6.5" fill="${INK}"/><circle cx="${cx + 2.2}" cy="${cy - 2.2}" r="2" fill="#fff"/>`;
    const faces = {
      idle: `<g class="pet-blink">${eye(84, 106)}${eye(116, 106)}</g>
        <path d="M95 120 Q100 125 105 120" fill="none" stroke="${INK}" stroke-width="3" stroke-linecap="round"/>`,
      happy: `<path d="M76 108 Q84 97 92 108 M108 108 Q116 97 124 108" fill="none" stroke="${INK}" stroke-width="4.5" stroke-linecap="round"/>
        <path d="M93 117 Q100 129 107 117 Z" fill="${INK}" stroke="${INK}" stroke-width="2" stroke-linejoin="round"/>`,
      sleep: `<path d="M76 105 Q84 111 92 105 M108 105 Q116 111 124 105" fill="none" stroke="${INK}" stroke-width="4" stroke-linecap="round"/>
        <ellipse cx="100" cy="121" rx="3" ry="2.5" fill="${INK}"/>`,
      work: `<g class="pet-blink">${eye(89, 101)}${eye(121, 101)}</g>
        <path d="M96 121 L105 120" fill="none" stroke="${INK}" stroke-width="3" stroke-linecap="round"/>
        <circle class="pet-dot" cx="146" cy="46" r="3.5" fill="#A897FF"/>
        <circle class="pet-dot d2" cx="157" cy="34" r="4.5" fill="#A897FF"/>
        <circle class="pet-dot d3" cx="170" cy="20" r="6" fill="#A897FF"/>`
    };
    const ring = `<ellipse cx="100" cy="112" rx="82" ry="19" fill="none" stroke="#A897FF" stroke-width="2.5"/>`;
    const sat = state === 'sleep' ? '#8D86B8' : '#5CF2E0';
    return wrap(state, `
      ${shadow(36)}
      <g class="pet-body">
        <circle cx="100" cy="106" r="76" fill="url(#flu-glow)" opacity="${state === 'sleep' ? 0.4 : 1}"/>
        <g transform="rotate(-10 100 112)" opacity=".55">${ring}</g>
        <path d="M100 46 C141 46 162 80 162 116 C162 147 135 162 100 162 C65 162 38 147 38 116 C38 80 59 46 100 46 Z" fill="url(#flu-body)"/>
        <ellipse cx="76" cy="74" rx="13" ry="7" fill="#fff" opacity=".55" transform="rotate(-32 76 74)"/>
        <ellipse cx="69" cy="119" rx="8" ry="4.5" fill="#FF8FB8" opacity=".55"/>
        <ellipse cx="131" cy="119" rx="8" ry="4.5" fill="#FF8FB8" opacity=".55"/>
        ${faces[state]}
        <g transform="rotate(-10 100 112)">
          <g clip-path="url(#flu-front)" opacity=".8">${ring}</g>
          <circle class="${state === 'work' ? 'pet-pulse' : ''}" cx="181" cy="110" r="6" fill="${sat}"/>
        </g>
      </g>
      ${state === 'sleep' ? zz(138, 44, '#9B8BFF') : ''}`, defs);
  }

  // 3. Нэко — кот-дрон: голова с визором и двигатель вместо лап.
  function neko(state) {
    const A = '#FFB547';
    const HEAD = '#2B303B';
    const faces = {
      idle: `<g class="pet-blink"><rect x="78" y="98" width="14" height="16" rx="5" fill="${A}"/>
        <rect x="108" y="98" width="14" height="16" rx="5" fill="${A}"/></g>`,
      happy: `<path d="M78 112 Q85 99 92 112 M108 112 Q115 99 122 112" fill="none" stroke="${A}" stroke-width="4.5" stroke-linecap="round"/>`,
      sleep: `<path d="M79 107 L91 107 M109 107 L121 107" fill="none" stroke="${A}" stroke-width="4" stroke-linecap="round" opacity=".55"/>`,
      work: `<rect x="66" y="105" width="68" height="2" rx="1" fill="${A}" opacity=".25"/>
        <rect class="pet-scan" x="66" y="102" width="20" height="8" rx="4" fill="${A}"/>`
    };
    const thrust = state === 'sleep' ? '' :
      `<ellipse class="pet-thrust" cx="100" cy="166" rx="18" ry="7" fill="${A}" filter="url(#neko-blur)"/>`;
    const defs = `<filter id="neko-blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3.5"/></filter>`;
    return wrap(state, `
      ${shadow(38)}
      <g class="pet-body">
        ${thrust}
        <rect x="83" y="140" width="34" height="16" rx="6" fill="#3A4050"/>
        <rect x="90" y="153" width="20" height="4" rx="2" fill="${state === 'sleep' ? '#555C6B' : A}"/>
        <g stroke="#8E97A8" stroke-width="2.5" stroke-linecap="round">
          <path d="M52 113 L27 108 M52 121 L27 124 M148 113 L173 108 M148 121 L173 124"/>
        </g>
        <path d="M55 86 L61 42 L93 66 Z M145 86 L139 42 L107 66 Z" fill="${HEAD}" stroke="${HEAD}" stroke-width="10" stroke-linejoin="round"/>
        <path d="M65 74 L68 55 L82 65 Z M135 74 L132 55 L118 65 Z" fill="${A}" opacity=".85" stroke="${A}" stroke-width="3" stroke-linejoin="round"/>
        <rect x="44" y="62" width="112" height="86" rx="40" fill="${HEAD}" stroke="#454C5C" stroke-width="2"/>
        <path d="M62 80 Q72 68 90 66" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" opacity=".1"/>
        <rect x="60" y="86" width="80" height="40" rx="20" fill="#11141A"/>
        ${faces[state]}
        <path d="M93 134 Q96.5 138.5 100 134 Q103.5 138.5 107 134" fill="none" stroke="#8E97A8" stroke-width="2.5" stroke-linecap="round"/>
      </g>
      ${state === 'sleep' ? zz(140, 46, '#8E97A8') : ''}`, defs);
  }

  const PETS = [
    { id: 'bit', render: bit },
    { id: 'flu', render: flu },
    { id: 'neko', render: neko }
  ];

  root.Pets = { STATES, CSS, PETS, render: (id, state) => PETS.find((p) => p.id === id).render(state) };
})(typeof window !== 'undefined' ? window : globalThis);

// Выгружает каждого питомца в каждом состоянии в отдельный SVG с анимациями: references/svg/<id>-<state>.svg
// Запуск из корня проекта: node tools/export-svg.js
const fs = require('fs');
const path = require('path');

require('../references/pets.js');
const { Pets } = globalThis;

const outDir = path.join(__dirname, '..', 'references', 'svg');
fs.mkdirSync(outDir, { recursive: true });

for (const pet of Pets.PETS) {
  for (const state of Pets.STATES) {
    const svg = Pets.render(pet.id, state).replace('>', `><style>${Pets.CSS}</style>`);
    fs.writeFileSync(path.join(outDir, `${pet.id}-${state}.svg`), svg);
  }
}
console.log(`SVG: ${Pets.PETS.length * Pets.STATES.length} файлов в ${outDir}`);

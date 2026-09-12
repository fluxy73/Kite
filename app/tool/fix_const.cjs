// Passe unique : supprime le mot-clé `const` devant toute expression
// dont le span (parenthèses équilibrées) contient une référence runtime
// KiteColors.* (tokens devenus des getters pilotés par le mode).
const fs = require('fs');
const path = require('path');

const roots = ['lib', 'test'];

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.dart')) out.push(p);
  }
  return out;
}

let removed = 0;
for (const root of roots) {
  if (!fs.existsSync(root)) continue;
  for (const file of walk(root, [])) {
    let s = fs.readFileSync(file, 'utf8');
    let out = '';
    let i = 0;
    while (i < s.length) {
      const idx = s.indexOf('const', i);
      if (idx === -1) { out += s.slice(i); break; }
      const before = idx > 0 ? s[idx - 1] : '';
      const after = s[idx + 5];
      const isWord = (c) => /[A-Za-z0-9_$]/.test(c);
      if (isWord(before) || isWord(after)) { out += s.slice(i, idx + 5); i = idx + 5; continue; }
      // début du span : premier jeton significatif après `const`
      let j = idx + 5;
      while (j < s.length && /\s/.test(s[j])) j++;
      // saute le nom du constructeur (ex. TextStyle) et ses génériques
      let k = j;
      while (k < s.length && /[A-Za-z0-9_<>.,\s?]/.test(s[k])) k++;
      let end = -1;
      const open = s[k];
      const pairs = { '(': ')', '[': ']', '{': '}' };
      if (pairs[open]) {
        let depth = 0;
        let inStr = null;
        for (let c = k; c < s.length; c++) {
          const ch = s[c];
          if (inStr) {
            if (ch === '\\') { c++; continue; }
            if (ch === inStr) inStr = null;
            continue;
          }
          if (ch === "'" || ch === '"') { inStr = ch; continue; }
          if (ch === '(' || ch === '[' || ch === '{') depth++;
          else if (ch === ')' || ch === ']' || ch === '}') {
            depth--;
            if (depth === 0) { end = c + 1; break; }
          }
        }
        if (end === -1) end = s.length;
      } else {
        end = s.indexOf('\n', j);
        if (end === -1) end = s.length;
      }
      const span = s.slice(idx, end);
      if (span.includes('KiteColors.')) {
        out += s.slice(i, idx);
        i = idx + 5; // garde les espaces qui suivaient `const`
        removed++;
      } else {
        out += s.slice(i, idx + 5);
        i = idx + 5;
      }
    }
    if (out !== s) fs.writeFileSync(file, out);
  }
}
console.log('const removed:', removed);

// The web's icon set as template images for the Apple apps, so both draw
// the same icons:
//   node tools/apple_icons.mjs
// Reads assets/web/icons.svg; writes one vector imageset per icon under
// clients/apple/App/Resources/Design.xcassets/Icons (named "Icons/<id>").
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..");
const sprite = readFileSync(join(root, "assets/web/icons.svg"), "utf8");
const out = join(root, "clients/apple/App/Resources/Design.xcassets/Icons");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
writeFileSync(join(out, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 }, properties: { "provides-namespace": true } }, null, 2) + "\n");
let count = 0;
for (const [, id, viewBox, body] of sprite.matchAll(/<symbol id="([^"]+)" viewBox="([^"]+)">(.*?)<\/symbol>/g)) {
  const [, , width, height] = viewBox.split(" ").map(Number);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="${viewBox}" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${body.replaceAll("currentColor", "#000")}</svg>\n`;
  const set = join(out, `${id}.imageset`);
  mkdirSync(set);
  writeFileSync(join(set, `${id}.svg`), svg);
  writeFileSync(join(set, "Contents.json"), JSON.stringify({ images: [{ filename: `${id}.svg`, idiom: "universal" }], info: { author: "xcode", version: 1 }, properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" } }, null, 2) + "\n");
  count++;
}
console.log(`${count} icons`);

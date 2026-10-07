// Every journey, one after another, against the executable given first:
//   node tests/e2e.mjs zig-out/bin/analytico
for (const name of ["cli", "browser", "http", "workspace", "ai", "v3", "ux"]) await import(`./${name}.mjs`);
console.log("e2e ok");

// Generates the four seeded 512x512 grayscale noise tiles the composition
// cycles per-frame (frame % 4) to dither the plum gradients before any encoder
// sees them. Pure Node - a minimal PNG writer over zlib, no dependencies, so
// the tiles are reproducible from seed alone: mulberry32(7..10), +/-6 around
// mid-gray, matching the plan's 5%-overlay grain spec.
"use strict";
const zlib = require("zlib");
const fs = require("fs");
const path = require("path");

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, "ascii"), data])), 8 + data.length);
  return out;
}
function grayPng(size, pixels) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 0; // 8-bit grayscale
  const raw = Buffer.alloc(size * (size + 1));
  for (let y = 0; y < size; y++) {
    raw[y * (size + 1)] = 0; // filter: none
    pixels.copy(raw, y * (size + 1) + 1, y * size, (y + 1) * size);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const SIZE = 512;
const outDir = path.join(__dirname, "composition", "grain");
fs.mkdirSync(outDir, { recursive: true });
for (let i = 0; i < 4; i++) {
  const rnd = mulberry32(7 + i);
  const px = Buffer.alloc(SIZE * SIZE);
  for (let p = 0; p < px.length; p++) px[p] = 128 + Math.round((rnd() * 2 - 1) * 6);
  const file = path.join(outDir, `g${i}.png`);
  fs.writeFileSync(file, grayPng(SIZE, px));
  console.log(`${file}  ${fs.statSync(file).size} bytes`);
}

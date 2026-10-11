import { build } from 'esbuild';
import { copyFile } from 'node:fs/promises';
await build({ entryPoints: ['bridge.ts'], outfile: '../Resources/RealtimePreview/preview.js', bundle: true, minify: true, platform: 'browser', format: 'iife', target: 'safari16' });
await copyFile('node_modules/pdfjs-dist/legacy/build/pdf.worker.min.mjs', '../Resources/RealtimePreview/pdf.worker.mjs');
await copyFile('index.html', '../Resources/RealtimePreview/index.html');

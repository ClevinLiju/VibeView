// Bundles the renderer with esbuild (three.js is bundled locally, no CDN).
const path = require('path');
const fs = require('fs');
const esbuild = require('esbuild');

const root = path.resolve(__dirname, '..');
const watch = process.argv.includes('--watch');

async function main() {
  if (!fs.existsSync(path.join(root, 'build', 'icon.ico'))) require(path.join(root, 'build', 'make-icon.js'));
  const opts = {
    entryPoints: [path.join(root, 'renderer', 'src', 'main.js')],
    bundle: true,
    outfile: path.join(root, 'renderer', 'dist', 'bundle.js'),
    format: 'iife',
    platform: 'browser',
    target: ['chrome130'],
    sourcemap: true,
    minify: !watch && !process.argv.includes('--no-minify'),
    legalComments: 'linked',
    logLevel: 'info',
  };
  if (watch) {
    const ctx = await esbuild.context(opts);
    await ctx.watch();
  } else {
    await esbuild.build(opts);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });

const SOURCE_ROOT = new URL("../sources/catppuccin/", import.meta.url);
const STYLES_ROOT = new URL("styles/", SOURCE_ROOT);
const VENDOR_ROOT = new URL("vendor/", SOURCE_ROOT);
const SHARED_IMPORT = "https://userstyles.catppuccin.com/lib/lib.less";
const REVISION = "5ef4cc64231826f46d12a2721fa72571f5aa8a27";

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([first], [second]) => first.localeCompare(second))
      .map(([key, item]) => [key, sortKeys(item)]),
  );
}

function baselineSource(source: string): string {
  return source
    .replaceAll("@{lightFlavor}", "mocha")
    .replaceAll("@{darkFlavor}", "mocha")
    .replaceAll("@{accentColor}", "mauve");
}

function externalImports(source: string): string[] {
  const urls = new Set<string>();
  for (const statement of baselineSource(source).match(/@import[\s\S]*?;/g) ?? []) {
    const url = statement.match(/(?:url\(\s*["']([^"']+)["']\s*\)|["'](https?:\/\/[^"']+)["'])/)?.[1]
      ?? statement.match(/(?:url\(\s*["']([^"']+)["']\s*\)|["'](https?:\/\/[^"']+)["'])/)?.[2];
    if (url && url !== SHARED_IMPORT) urls.add(url);
  }
  return [...urls].sort();
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function filename(url: string, digest: string): string {
  const parsed = new URL(url);
  const host = parsed.hostname.replace(/[^A-Za-z0-9]+/g, "-");
  const base = decodeURIComponent(parsed.pathname.split("/").at(-1) || "style.css")
    .replace(/[^A-Za-z0-9._-]+/g, "-");
  return `${host}-${base}-${digest.slice(0, 12)}.css`;
}

async function main(): Promise<void> {
  const sources = new Set<string>();
  for await (const entry of Deno.readDir(STYLES_ROOT)) {
    if (!entry.isDirectory) continue;
    const path = new URL(`${encodeURIComponent(entry.name)}/catppuccin.user.less`, STYLES_ROOT);
    for (const url of externalImports(await Deno.readTextFile(path))) sources.add(url);
  }

  await Deno.mkdir(VENDOR_ROOT, {recursive: true});
  const imports: Record<string, {file: string; sha256: string; bytes: number}> = {};
  for (const url of [...sources].sort()) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status} ${response.statusText}`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    const digest = await sha256(bytes);
    const file = filename(url, digest);
    await Deno.writeFile(new URL(file, VENDOR_ROOT), bytes);
    imports[url] = {file, sha256: digest, bytes: bytes.byteLength};
  }

  const manifest = {
    schema_version: 1,
    upstream_revision: REVISION,
    baseline: {lightFlavor: "mocha", darkFlavor: "mocha", accentColor: "mauve"},
    imports,
  };
  await Deno.writeTextFile(
    new URL("manifest.json", VENDOR_ROOT),
    `${JSON.stringify(sortKeys(manifest), null, 2)}\n`,
  );
  console.log(`pinned ${Object.keys(imports).length} Catppuccin CSS imports`);
}

if (import.meta.main) await main();

import less from "npm:less@4.2.2";

const SOURCE_ROOT = new URL("../sources/catppuccin/", import.meta.url);
const STYLES_ROOT = new URL("styles/", SOURCE_ROOT);
const OUTPUT_ROOT = new URL("compiled/", SOURCE_ROOT);
const VENDOR_ROOT = new URL("vendor/", SOURCE_ROOT);
const SHARED_IMPORT = "https://userstyles.catppuccin.com/lib/lib.less";
const UPSTREAM_URL = "https://github.com/catppuccin/userstyles";
const REVISION = "5ef4cc64231826f46d12a2721fa72571f5aa8a27";

type StyleRecord = {
  id: string;
  name: string;
  version: string;
  source: string;
  template: string;
  source_sha256: string;
  document_blocks: number;
  unmaintained: boolean;
  remote_imports: string[];
};

type ExcludedRecord = {
  id: string;
  source: string;
  reasons: string[];
};

type VendorRecord = {
  file: string;
  sha256: string;
  bytes: number;
};

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([first], [second]) => first.localeCompare(second))
      .map(([key, item]) => [key, sortKeys(item)]),
  );
}

function json(value: unknown): string {
  return `${JSON.stringify(sortKeys(value), null, 2)}\n`;
}

async function sha256(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function metadataValue(source: string, key: string): string {
  const match = source.match(new RegExp(`^@${key}\\s+(.+)$`, "m"));
  if (!match) throw new Error(`missing @${key}`);
  return match[1].trim();
}

function defaultVariableValue(type: string, body: string): string {
  if (type === "select") {
    const options = body.match(/\[([^\]]+)\]/)?.[1];
    if (!options) throw new Error(`select variable has no options: ${body}`);
    const selected = options.split(/,\s*/).find((option) => option.includes("*")) ?? options.split(/,\s*/)[0];
    return selected.replace(/^\s*["']?/, "").split(":", 1)[0].replace(/\*\s*["']?$/, "");
  }
  if (type === "checkbox") {
    const match = body.match(/(-?\d+(?:\.\d+)?)\s*$/);
    if (!match) throw new Error(`checkbox variable has no numeric default: ${body}`);
    return match[1];
  }
  if (type === "text") {
    const quoted = [...body.matchAll(/"((?:\\.|[^"])*)"/g)];
    if (!quoted.length) throw new Error(`text variable has no default: ${body}`);
    return quoted.at(-1)![1];
  }
  throw new Error(`unsupported UserCSS variable type: ${type}`);
}

function defaultVariables(source: string): Record<string, string> {
  const variables: Record<string, string> = {};
  for (const line of source.split("\n")) {
    const match = line.match(/^\s*@var\s+(\w+)\s+(\w+)\s+(.+)$/);
    if (match) variables[match[2]] = defaultVariableValue(match[1], match[3]);
  }
  // Compile one stable dark Catppuccin baseline. The Blox renderer replaces
  // these palette values with the active theme, so the source light/dark
  // split must not leak into the generated UserCSS.
  variables.lightFlavor = "mocha";
  variables.darkFlavor = "mocha";
  variables.accentColor = "mauve";
  Object.assign(variables, {
    contrastColor: "red",
    graphUseAccentColor: "0",
    highlightColor1: "red",
    highlightColor2: "green",
    highlightColor3: "peach",
    highlightColor4: "blue",
    lastMoveColor: "red",
    checkColor: "red",
    styleBoardAndPieces: "1",
    stylePieces: "1",
    styleBoard: "1",
    styleVideoPlayer: "1",
    sponsorBlock: "1",
    logo: "1",
    oled: "0",
    additions: "0",
    zen: "0",
    "bg-opacity": "0.2",
    "bg-blur": "20px",
    urls: "127\\.0\\.0\\.1\\:8384,0\\.0\\.0\\.0\\:8384,localhost\\:8384",
    "highlight-redirect": "0",
  });
  return variables;
}

function externalImports(source: string): string[] {
  const urls = new Set<string>();
  const baseline = source
    .replaceAll("@{lightFlavor}", "mocha")
    .replaceAll("@{darkFlavor}", "mocha")
    .replaceAll("@{accentColor}", "mauve");
  for (const statement of baseline.match(/@import[\s\S]*?;/g) ?? []) {
    const match = statement.match(/(?:url\(\s*["']([^"']+)["']\s*\)|["'](https?:\/\/[^"']+)["'])/);
    const url = match?.[1] ?? match?.[2];
    if (url && url !== SHARED_IMPORT) urls.add(url);
  }
  return [...urls].sort();
}

function unmaintained(source: string): boolean {
  return /unmaintained/i.test(source);
}

async function readStyle(id: string): Promise<{ source: string; path: URL }> {
  const path = new URL(`${encodeURIComponent(id)}/catppuccin.user.less`, STYLES_ROOT);
  return {source: await Deno.readTextFile(path), path};
}

async function readVendorManifest(): Promise<Map<string, VendorRecord>> {
  const path = new URL("manifest.json", VENDOR_ROOT);
  const manifest = JSON.parse(await Deno.readTextFile(path)) as {upstream_revision?: string; imports?: Record<string, VendorRecord>};
  if (manifest.upstream_revision !== REVISION || !manifest.imports)
    throw new Error(`Catppuccin vendor manifest is missing or pinned to the wrong revision: ${path.pathname}`);

  const records = new Map<string, VendorRecord>();
  for (const [url, record] of Object.entries(manifest.imports)) {
    const bytes = await Deno.readFile(new URL(record.file, VENDOR_ROOT));
    const digest = await sha256(bytes);
    if (digest !== record.sha256 || bytes.byteLength !== record.bytes)
      throw new Error(`vendored CSS changed: ${record.file}`);
    records.set(url, record);
  }
  return records;
}

function localiseImports(source: string, vendors: Map<string, VendorRecord>): string {
  const localImport = source.replace(
    `@import "${SHARED_IMPORT}";`,
    '@import "../../lib/lib.less";',
  );
  return localImport.replace(/@import[\s\S]*?;/g, (statement) => {
    const baseline = statement
      .replaceAll("@{lightFlavor}", "mocha")
      .replaceAll("@{darkFlavor}", "mocha")
      .replaceAll("@{accentColor}", "mauve");
    const match = baseline.match(/(?:url\(\s*["']([^"']+)["']\s*\)|["'](https?:\/\/[^"']+)["'])/);
    const url = match?.[1] ?? match?.[2];
    if (!url || url === SHARED_IMPORT) return statement;

    const vendor = vendors.get(url);
    if (!vendor) throw new Error(`no pinned CSS import for ${url}`);
    const path = `../../vendor/${vendor.file}`;
    let replacement = baseline.replace(/\(\s*css\s*\)/g, "(inline)");
    replacement = replacement.replace(`url("${url}")`, `"${path}"`);
    replacement = replacement.replace(`url('${url}')`, `"${path}"`);
    replacement = replacement.replace(`"${url}"`, `"${path}"`);
    replacement = replacement.replace(`'${url}'`, `"${path}"`);
    if (!replacement.includes("(inline)")) replacement = replacement.replace("@import", "@import (inline)");
    return replacement;
  });
}

async function compile(source: string, path: URL, id: string, vendors: Map<string, VendorRecord>): Promise<string> {
  const localImport = localiseImports(source, vendors);
  const result = await less.render(localImport, {
    filename: path.pathname,
    paths: [new URL("lib/", SOURCE_ROOT).pathname],
    globalVars: defaultVariables(source),
    javascriptEnabled: false,
    compress: false,
  });
  const css = result.css.replace(/\/\* ==UserStyle==[\s\S]*?==\/UserStyle== \*\/\s*/, "").trim();
  if (!css.includes("@-moz-document")) throw new Error(`${id}: compiled output has no @-moz-document block`);
  if (/@import\s/.test(css)) throw new Error(`${id}: compiled output still contains an import`);
  return `/* Compiled from Catppuccin Userstyles ${REVISION}; do not edit. */\n${css}\n`;
}

async function main(): Promise<void> {
  await Deno.mkdir(OUTPUT_ROOT, {recursive: true});
  const vendors = await readVendorManifest();
  for await (const entry of Deno.readDir(OUTPUT_ROOT)) {
    if (entry.isFile && entry.name.endsWith(".css")) await Deno.remove(new URL(entry.name, OUTPUT_ROOT));
  }

  const records: StyleRecord[] = [];
  const excluded: ExcludedRecord[] = [];
  for await (const entry of Deno.readDir(STYLES_ROOT)) {
    if (!entry.isDirectory) continue;
    const id = entry.name;
    const {source, path} = await readStyle(id);
    const sourcePath = `styles/${id}/catppuccin.user.less`;
    const isUnmaintained = unmaintained(await Deno.readTextFile(new URL("README.md", new URL(`${encodeURIComponent(id)}/`, STYLES_ROOT))).catch(() => ""));
    const imports = externalImports(source);
    let output: string;
    let name: string;
    let version: string;
    try {
      output = await compile(source, path, id, vendors);
      name = metadataValue(source, "name");
      version = metadataValue(source, "version");
    } catch (error) {
      excluded.push({id, source: sourcePath, reasons: [error instanceof Error ? error.message : String(error)]});
      continue;
    }
    const template = `compiled/${id}.css`;
    await Deno.writeTextFile(new URL(`${encodeURIComponent(id)}.css`, OUTPUT_ROOT), output);
    records.push({
      id,
      name,
      version,
      source: sourcePath,
      template,
      source_sha256: await sha256(source),
      document_blocks: (output.match(/@-moz-document/g) ?? []).length,
      unmaintained: isUnmaintained,
      remote_imports: imports,
    });
  }

  records.sort((first, second) => first.id.localeCompare(second.id));
  excluded.sort((first, second) => first.id.localeCompare(second.id));
  await Deno.writeTextFile(new URL("manifest.json", SOURCE_ROOT), json({
    schema_version: 1,
    package: "blox-catppuccin-userstyles",
    upstream: {
      name: "Catppuccin Userstyles",
      url: UPSTREAM_URL,
      revision: REVISION,
      license: "MIT",
    },
    build: {
      compiler: "less",
      compiler_version: "4.2.2",
      command: "deno run -A themes/tools/build_catppuccin.ts",
      vendor_manifest: "vendor/manifest.json",
      palette_baseline: "mocha / mocha / mauve",
    },
    style_sets: {
      recommended: records.filter((record) => !record.unmaintained && record.remote_imports.length === 0).length,
      unmaintained: records.filter((record) => !record.remote_imports.length).length,
      all: records.length,
    },
    styles: records,
    excluded,
  }));
  console.log(`compiled ${records.length} styles; excluded ${excluded.length}`);
}

if (import.meta.main) await main();

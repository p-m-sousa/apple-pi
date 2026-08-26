/**
 * ApplePi bridge v1.
 *
 * This is an ordinary Pi extension, deliberately limited to APIs Pi itself exports.
 * It never evaluates code or invokes a shell. It reads only package manifests at
 * install paths returned by Pi's package manager; explicit package refreshes may use
 * Pi's own update checker. The native app sends a versioned base64url JSON envelope
 * to the reserved command and receives a reserved notify payload over Pi's extension
 * UI RPC channel.
 */
import {
  DefaultPackageManager,
  getAgentDir,
  hasTrustRequiringProjectResources,
  ProjectTrustStore,
  SettingsManager,
  VERSION,
  type ExtensionAPI,
  type ExtensionCommandContext,
  type PackageSource,
  type ResolvedResource,
} from "@earendil-works/pi-coding-agent";
import { readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const COMMAND = "apple-pi-bridge";
const PREFIX = "__APPLE_PI_BRIDGE_V1__:";
const VERSION_NUMBER = 1;
const MAX_ARGUMENT_LENGTH = 2 * 1024 * 1024;
const RESOURCE_KINDS = ["extensions", "skills", "prompts", "themes"] as const;

type ResourceKind = (typeof RESOURCE_KINDS)[number];
type JsonObject = Record<string, unknown>;

interface EnvelopeV1 {
  version: 1;
  requestID: string;
  nonce: string;
  action: string;
  payload: JsonObject;
}

interface ResponseV1 {
  version: 1;
  requestID: string;
  nonce: string;
  success: boolean;
  result?: unknown;
  error?: string;
}

function decodeBase64URL(value: string): string {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(normalized, "base64").toString("utf8");
}

function encodeBase64URL(value: string): string {
  return Buffer.from(value, "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function parseEnvelope(args: string): EnvelopeV1 {
  const encoded = args.trim();
  if (!encoded || encoded.length > MAX_ARGUMENT_LENGTH) {
    throw new Error("Bridge payload is empty or exceeds its safety limit.");
  }
  const value: unknown = JSON.parse(decodeBase64URL(encoded));
  if (!value || typeof value !== "object") throw new Error("Bridge payload must be an object.");
  const envelope = value as Partial<EnvelopeV1>;
  if (envelope.version !== VERSION_NUMBER) throw new Error("Unsupported bridge version.");
  if (typeof envelope.requestID !== "string" || envelope.requestID.length < 1 || envelope.requestID.length > 128) {
    throw new Error("Invalid bridge request ID.");
  }
  if (typeof envelope.nonce !== "string" || envelope.nonce.length < 16 || envelope.nonce.length > 256) {
    throw new Error("Invalid bridge nonce.");
  }
  if (typeof envelope.action !== "string") throw new Error("Invalid bridge action.");
  if (!envelope.payload || typeof envelope.payload !== "object" || Array.isArray(envelope.payload)) {
    throw new Error("Bridge payload field must be an object.");
  }
  return envelope as EnvelopeV1;
}

function respond(ctx: ExtensionCommandContext, response: ResponseV1): void {
  const encoded = encodeBase64URL(JSON.stringify(response));
  ctx.ui.notify(`${PREFIX}${encoded}`, "info");
}

function stringField(payload: JsonObject, key: string, required = true): string | undefined {
  const value = payload[key];
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string" || value.includes("\0")) throw new Error(`Invalid ${key}.`);
  return value;
}

function booleanField(payload: JsonObject, key: string): boolean {
  const value = payload[key];
  if (typeof value !== "boolean") throw new Error(`Invalid ${key}.`);
  return value;
}

function stripDirective(value: string): string {
  return /^[!+-]/.test(value) ? value.slice(1) : value;
}

function resourcePattern(resource: ResolvedResource): string {
  const base = resource.metadata.baseDir;
  return base ? relative(base, resource.path) : resource.path;
}

function packageManager(ctx: ExtensionCommandContext) {
  const agentDir = getAgentDir();
  const settings = SettingsManager.create(ctx.cwd, agentDir, { projectTrusted: ctx.isProjectTrusted() });
  return new DefaultPackageManager({ cwd: ctx.cwd, agentDir, settingsManager: settings });
}

function installedPackageVersion(installedPath: string | undefined): string | undefined {
  if (!installedPath) return undefined;
  try {
    const manifest = join(installedPath, "package.json");
    if (statSync(manifest).size > 1024 * 1024) return undefined;
    const value: unknown = JSON.parse(readFileSync(manifest, "utf8"));
    if (!value || typeof value !== "object") return undefined;
    const version = (value as { version?: unknown }).version;
    return typeof version === "string" && version.length <= 128 ? version : undefined;
  } catch {
    return undefined;
  }
}

async function resourceSnapshot(ctx: ExtensionCommandContext, includeUpdateCheck = false) {
  const manager = packageManager(ctx);
  const configuredPackages = manager.listConfiguredPackages();
  let availableUpdates: Array<{ source: string; scope: string }> = [];
  if (includeUpdateCheck) {
    try {
      availableUpdates = (await manager.checkForAvailableUpdates()).map((update) => ({
        source: update.source,
        scope: update.scope,
      }));
    } catch {
      // Inventory remains useful when a registry or git remote is unavailable.
    }
  }
  const updateKeys = new Set(availableUpdates.map((update) => `${update.scope}\0${update.source}`));
  return manager.resolve(async () => "skip").then((resolved) => ({
    configuredPackages: configuredPackages.map((item) => ({
      ...item,
      installedVersion: installedPackageVersion(item.installedPath),
      hasUpdate: updateKeys.has(`${item.scope}\0${item.source}`),
    })),
    resources: RESOURCE_KINDS.flatMap((kind) => resolved[kind].map((item) => ({
      source: item.metadata.source,
      scope: item.metadata.scope,
      origin: item.metadata.origin,
      baseDir: item.metadata.baseDir,
      kind,
      path: item.path,
      pattern: resourcePattern(item),
      enabled: item.enabled,
    }))),
  }));
}

function setTopLevelPatterns(
  settings: SettingsManager,
  scope: "user" | "project",
  kind: ResourceKind,
  pattern: string,
  enabled: boolean,
): void {
  const source = scope === "project" ? settings.getProjectSettings() : settings.getGlobalSettings();
  const current = [...(source[kind] ?? [])];
  const updated = current.filter((entry) => stripDirective(entry) !== pattern);
  updated.push(`${enabled ? "+" : "-"}${pattern}`);

  if (scope === "project") {
    if (kind === "extensions") settings.setProjectExtensionPaths(updated);
    else if (kind === "skills") settings.setProjectSkillPaths(updated);
    else if (kind === "prompts") settings.setProjectPromptTemplatePaths(updated);
    else settings.setProjectThemePaths(updated);
  } else {
    if (kind === "extensions") settings.setExtensionPaths(updated);
    else if (kind === "skills") settings.setSkillPaths(updated);
    else if (kind === "prompts") settings.setPromptTemplatePaths(updated);
    else settings.setThemePaths(updated);
  }
}

function packageSourceName(source: PackageSource): string {
  return typeof source === "string" ? source : source.source;
}

function setPackagePattern(
  settings: SettingsManager,
  scope: "user" | "project",
  sourceName: string,
  kind: ResourceKind,
  pattern: string,
  enabled: boolean,
): void {
  const sourceSettings = scope === "project" ? settings.getProjectSettings() : settings.getGlobalSettings();
  const packages: PackageSource[] = [...(sourceSettings.packages ?? [])];
  let index = packages.findIndex((item) => packageSourceName(item) === sourceName);
  if (index < 0) {
    if (scope !== "project") throw new Error("The package is not configured in the requested scope.");
    packages.push({ source: sourceName, autoload: false });
    index = packages.length - 1;
  }

  const existing = packages[index];
  const packageObject = typeof existing === "string" ? { source: existing } : { ...existing };
  const current = [...(packageObject[kind] ?? [])];
  const updated = current.filter((entry) => stripDirective(entry) !== pattern);
  updated.push(`${enabled ? "+" : "-"}${pattern}`);
  packageObject[kind] = updated;
  packages[index] = packageObject;
  if (scope === "project") settings.setProjectPackages(packages);
  else settings.setPackages(packages);
}

async function dispatch(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  envelope: EnvelopeV1,
): Promise<unknown> {
  const payload = envelope.payload;
  switch (envelope.action) {
    case "ping":
      return { bridgeVersion: VERSION_NUMBER, piVersion: VERSION, mode: ctx.mode };
    case "capabilities":
      return {
        actions: [
          "ping", "capabilities", "trust_resolve", "trust_set", "navigate_tree",
          "set_label", "package_snapshot", "resource_snapshot", "set_resource_enabled", "reload",
        ],
        projectTrusted: ctx.isProjectTrusted(),
        cwd: ctx.cwd,
      };
    case "trust_resolve": {
      const cwd = stringField(payload, "cwd", false) ?? ctx.cwd;
      return {
        cwd,
        requiresTrust: hasTrustRequiringProjectResources(cwd),
        entry: new ProjectTrustStore(getAgentDir()).getEntry(cwd),
      };
    }
    case "trust_set": {
      const cwd = stringField(payload, "cwd", false) ?? ctx.cwd;
      const decision = payload.decision;
      if (decision !== null && typeof decision !== "boolean") throw new Error("Invalid trust decision.");
      new ProjectTrustStore(getAgentDir()).set(cwd, decision);
      return { cwd, decision };
    }
    case "navigate_tree": {
      const targetID = stringField(payload, "targetID")!;
      const result = await ctx.navigateTree(targetID, {
        summarize: typeof payload.summarize === "boolean" ? payload.summarize : undefined,
        customInstructions: typeof payload.customInstructions === "string" ? payload.customInstructions : undefined,
        replaceInstructions: typeof payload.replaceInstructions === "boolean" ? payload.replaceInstructions : undefined,
        label: typeof payload.label === "string" ? payload.label : undefined,
      });
      return result;
    }
    case "set_label": {
      const entryID = stringField(payload, "entryID")!;
      const label = payload.label;
      if (label !== null && label !== undefined && typeof label !== "string") throw new Error("Invalid label.");
      pi.setLabel(entryID, label == null ? undefined : label);
      return { entryID, label: label ?? null };
    }
    case "package_snapshot":
      return resourceSnapshot(ctx, true);
    case "resource_snapshot":
      return resourceSnapshot(ctx);
    case "set_resource_enabled": {
      const kind = stringField(payload, "kind") as ResourceKind;
      if (!RESOURCE_KINDS.includes(kind)) throw new Error("Invalid resource kind.");
      const scope = stringField(payload, "scope") as "user" | "project";
      if (scope !== "user" && scope !== "project") throw new Error("Invalid resource scope.");
      if (scope === "project" && !ctx.isProjectTrusted()) throw new Error("Project trust is required.");
      const origin = stringField(payload, "origin")!;
      const sourceName = stringField(payload, "source")!;
      const pattern = stringField(payload, "pattern")!;
      const enabled = booleanField(payload, "enabled");
      const settings = SettingsManager.create(ctx.cwd, getAgentDir(), { projectTrusted: ctx.isProjectTrusted() });
      if (origin === "top-level") setTopLevelPatterns(settings, scope, kind, pattern, enabled);
      else if (origin === "package") setPackagePattern(settings, scope, sourceName, kind, pattern, enabled);
      else throw new Error("Invalid resource origin.");
      await settings.flush();
      await ctx.reload();
      return { kind, scope, source: sourceName, pattern, enabled };
    }
    case "reload":
      await ctx.reload();
      return { reloaded: true };
    default:
      throw new Error(`Unknown bridge action: ${envelope.action}`);
  }
}

export default function applePiBridge(pi: ExtensionAPI): void {
  pi.registerCommand(COMMAND, {
    description: "Private versioned control bridge for the ApplePi native client",
    handler: async (args, ctx) => {
      let envelope: EnvelopeV1 | undefined;
      try {
        envelope = parseEnvelope(args);
        const result = await dispatch(pi, ctx, envelope);
        respond(ctx, {
          version: VERSION_NUMBER,
          requestID: envelope.requestID,
          nonce: envelope.nonce,
          success: true,
          result,
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (envelope) {
          respond(ctx, {
            version: VERSION_NUMBER,
            requestID: envelope.requestID,
            nonce: envelope.nonce,
            success: false,
            error: message,
          });
        } else {
          ctx.ui.notify(`ApplePi bridge rejected a malformed request: ${message}`, "error");
        }
      }
    },
  });
}

import {
  app,
  BrowserWindow,
  clipboard,
  dialog,
  globalShortcut,
  ipcMain,
  Menu,
  nativeImage,
  session,
  shell,
  systemPreferences,
  Tray,
} from "electron";
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  AppPhase,
  DeliveryResult,
  PerformanceMetrics,
  RecordingSource,
  RuntimeStatus,
  Settings,
  TranscriptionResult,
} from "./shared";
import {
  parsePhysicalFootprints,
  parseProcessTable,
  PhysicalFootprintSnapshot,
  ProcessTreeSnapshot,
  selectProcessTree,
} from "./process-tree";

// Keep existing settings when the visible application name changes.
const existingUserData = path.join(app.getPath("appData"), "open-wisper");
mkdirSync(existingUserData, { recursive: true });
app.setPath("userData", existingUserData);
app.setName("Open Wisper Electron");
const primaryInstance = app.requestSingleInstanceLock();

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let isQuitting = false;
let settingsStore: SettingsStore;
let phase: AppPhase = "idle";
let peakWorkingSetMb = 0;
let latestProcessMetrics: PerformanceMetrics["processes"] = [];
let lastMemorySampleAt = 0;
let memorySampleTimer: NodeJS.Timeout | null = null;
let memorySampleInFlight = false;
const processPeakWorkingSetMb = new Map<number, { name: string; peakMb: number }>();
let lastTranscriptionMs: number | null = null;
let lastAudioDurationMs: number | null = null;
let foregroundBundleId: string | null = null;

class SettingsStore {
  private readonly filePath: string;
  private settings: Settings;

  constructor() {
    this.filePath = path.join(app.getPath("userData"), "settings.json");
    this.settings = this.load();
  }

  get(): Settings {
    return { ...this.settings };
  }

  update(patch: Partial<Settings>): Settings {
    this.settings = sanitizeSettings({ ...this.settings, ...patch });
    const temporaryPath = `${this.filePath}.tmp`;
    writeFileSync(temporaryPath, `${JSON.stringify(this.settings, null, 2)}\n`, "utf8");
    renameSync(temporaryPath, this.filePath);
    return this.get();
  }

  private load(): Settings {
    const defaults = defaultSettings();
    if (!existsSync(this.filePath)) return defaults;

    try {
      const saved = JSON.parse(readFileSync(this.filePath, "utf8")) as Partial<Settings>;
      return sanitizeSettings({ ...defaults, ...saved });
    } catch {
      return defaults;
    }
  }
}

function runtimeRoot(): string {
  return app.isPackaged ? path.join(process.resourcesPath, "runtime") : path.join(app.getAppPath(), "tools", "runtime");
}

function defaultSettings(): Settings {
  const root = runtimeRoot();
  return {
    whisperBinaryPath: firstExistingPath([
      path.join(root, "whisper-cli"),
      path.join(app.getAppPath(), "tools", "whisper.cpp", "build", "bin", "whisper-cli"),
    ]),
    modelPath: firstExistingPath([
      path.join(root, "ggml-tiny.en-q5_1.bin"),
      path.join(app.getAppPath(), "tools", "whisper.cpp", "models", "ggml-tiny.en-q5_1.bin"),
    ]),
    autoPaste: true,
    launchAtLogin: false,
    shortcut: "CommandOrControl+Shift+Space",
  };
}

function sanitizeSettings(settings: Settings): Settings {
  return {
    whisperBinaryPath: typeof settings.whisperBinaryPath === "string" ? settings.whisperBinaryPath : "",
    modelPath: typeof settings.modelPath === "string" ? settings.modelPath : "",
    autoPaste: Boolean(settings.autoPaste),
    launchAtLogin: Boolean(settings.launchAtLogin),
    shortcut: typeof settings.shortcut === "string" && settings.shortcut.trim()
      ? settings.shortcut.trim()
      : "CommandOrControl+Shift+Space",
  };
}

function firstExistingPath(candidates: string[]): string {
  return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0];
}

function createWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 440,
    height: 720,
    minWidth: 390,
    minHeight: 620,
    show: false,
    resizable: true,
    title: "Open Wisper Electron",
    titleBarStyle: "hiddenInset",
    backgroundColor: "#0b0e14",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
    },
  });

  window.loadFile(path.join(__dirname, "index.html"));
  window.on("close", (event) => {
    if (!isQuitting) {
      event.preventDefault();
      window.hide();
    }
  });
  window.on("closed", () => {
    mainWindow = null;
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("https://")) void shell.openExternal(url);
    return { action: "deny" };
  });

  return window;
}

function showWindow(): void {
  if (!mainWindow) mainWindow = createWindow();
  mainWindow.show();
  mainWindow.focus();
}

function createTray(): Tray {
  const statusTray = new Tray(nativeImage.createEmpty());
  statusTray.setTitle("●");
  statusTray.setToolTip("Open Wisper Electron");
  statusTray.on("click", showWindow);
  rebuildTrayMenu(statusTray);
  return statusTray;
}

function rebuildTrayMenu(statusTray = tray): void {
  if (!statusTray) return;
  const isRecording = phase === "recording";
  const isBusy = phase === "transcribing";
  const label = isRecording ? "Stop Recording" : isBusy ? "Transcribing…" : "Start Recording";

  statusTray.setTitle(isRecording ? "● REC" : isBusy ? "● …" : "●");
  statusTray.setContextMenu(Menu.buildFromTemplate([
    {
      label,
      enabled: !isBusy,
      click: () => sendRecordingCommand(isRecording ? "stop" : "start", "tray"),
    },
    { type: "separator" },
    { label: "Open Wisper Electron", click: showWindow },
    { label: "Quit", click: () => app.quit() },
  ]));
}

function sendRecordingCommand(action: "toggle" | "start" | "stop", source: RecordingSource): void {
  mainWindow?.webContents.send("recording-command", { action, source });
}

function registerShortcut(accelerator: string): boolean {
  globalShortcut.unregisterAll();
  return globalShortcut.register(accelerator, () => sendRecordingCommand("toggle", "shortcut"));
}

function setPhase(nextPhase: AppPhase): void {
  phase = nextPhase;
  rebuildTrayMenu();
  scheduleMemorySample(nextPhase === "transcribing" ? 0 : undefined);
}

function installIpcHandlers(): void {
  ipcMain.handle("settings:get", () => settingsStore.get());
  ipcMain.handle("settings:update", (_event, patch: Partial<Settings>) => {
    const previous = settingsStore.get();
    const updated = settingsStore.update(patch);

    if (updated.shortcut !== previous.shortcut && !registerShortcut(updated.shortcut)) {
      settingsStore.update({ shortcut: previous.shortcut });
      throw new Error(`The shortcut ${updated.shortcut} is already in use.`);
    }

    if (updated.launchAtLogin !== previous.launchAtLogin && app.isPackaged) {
      app.setLoginItemSettings({ openAtLogin: updated.launchAtLogin });
    }

    if (patch.autoPaste === true && process.platform === "darwin") {
      systemPreferences.isTrustedAccessibilityClient(true);
    }

    const finalSettings = settingsStore.get();
    mainWindow?.webContents.send("settings-changed", finalSettings);
    return finalSettings;
  });

  ipcMain.handle("runtime:status", async (): Promise<RuntimeStatus> => {
    const settings = settingsStore.get();
    return {
      binaryReady: isExecutable(settings.whisperBinaryPath),
      modelReady: isReadableFile(settings.modelPath),
      platform: process.platform,
      packaged: app.isPackaged,
    };
  });

  ipcMain.handle("runtime:choose-binary", async () => {
    const result = await dialog.showOpenDialog({
      title: "Choose whisper-cli",
      properties: ["openFile"],
      buttonLabel: "Use whisper-cli",
    });
    return result.canceled ? null : result.filePaths[0];
  });

  ipcMain.handle("runtime:choose-model", async () => {
    const result = await dialog.showOpenDialog({
      title: "Choose a whisper.cpp model",
      properties: ["openFile"],
      filters: [{ name: "whisper.cpp models", extensions: ["bin"] }],
      buttonLabel: "Use model",
    });
    return result.canceled ? null : result.filePaths[0];
  });

  ipcMain.handle("runtime:reveal-setup", () => {
    shell.showItemInFolder(path.join(app.getAppPath(), "scripts", "setup-whisper.sh"));
  });

  ipcMain.handle("recording:prepare", async (_event, source: RecordingSource) => {
    foregroundBundleId = null;
    if (source === "window") return;
    foregroundBundleId = await captureForegroundBundleId();
  });

  ipcMain.handle("phase:set", (_event, nextPhase: AppPhase) => setPhase(nextPhase));

  ipcMain.handle("transcribe", async (_event, wavData: ArrayBuffer, audioDurationMs: number) => {
    const settings = settingsStore.get();
    if (!isExecutable(settings.whisperBinaryPath)) {
      throw new Error("whisper-cli is missing or is not executable. Run pnpm setup:whisper or choose the binary in Settings.");
    }
    if (!isReadableFile(settings.modelPath)) {
      throw new Error("The model file is missing. Run pnpm setup:whisper or choose a .bin model in Settings.");
    }
    if (!(wavData instanceof ArrayBuffer) || wavData.byteLength < 45) {
      throw new Error("The captured recording is empty.");
    }

    setPhase("transcribing");
    const startedAt = performance.now();
    try {
      const text = await runWhisper(settings.whisperBinaryPath, settings.modelPath, Buffer.from(wavData));
      const elapsedMs = Math.round(performance.now() - startedAt);
      lastTranscriptionMs = elapsedMs;
      lastAudioDurationMs = Math.round(audioDurationMs);
      return { text: cleanTranscript(text), elapsedMs, audioDurationMs } satisfies TranscriptionResult;
    } finally {
      void sampleMemoryNow();
    }
  });

  ipcMain.handle("text:deliver", async (_event, text: string, allowAutoPaste: boolean): Promise<DeliveryResult> => {
    const trimmed = text.trim();
    if (!trimmed) return { copied: false, pasted: false, reason: "There is no transcript to deliver." };
    clipboard.writeText(trimmed);

    if (!allowAutoPaste || !settingsStore.get().autoPaste) {
      return { copied: true, pasted: false, reason: "Copied to clipboard." };
    }
    if (process.platform !== "darwin") {
      return { copied: true, pasted: false, reason: "Auto-paste is available on macOS; the transcript is on your clipboard." };
    }
    if (!foregroundBundleId) {
      return { copied: true, pasted: false, reason: "No target app was captured; the transcript is on your clipboard." };
    }
    if (!systemPreferences.isTrustedAccessibilityClient(true)) {
      return { copied: true, pasted: false, reason: "Enable Accessibility for Open Wisper, then try again. The transcript is on your clipboard." };
    }

    try {
      await pasteIntoApp(foregroundBundleId);
      return { copied: true, pasted: true };
    } catch (error) {
      return { copied: true, pasted: false, reason: `Auto-paste failed; the transcript is on your clipboard. ${errorMessage(error)}` };
    }
  });

  ipcMain.handle("metrics:get", () => collectMetrics());
}

async function runWhisper(binaryPath: string, modelPath: string, wavData: Buffer): Promise<string> {
  const workingDirectory = mkdtempSync(path.join(tmpdir(), "open-wisper-"));
  const wavPath = path.join(workingDirectory, "recording.wav");
  const outputBase = path.join(workingDirectory, "transcript");
  writeFileSync(wavPath, wavData);

  try {
    const args = ["-m", modelPath, "-f", wavPath, "-l", "en", "-nt", "-otxt", "-of", outputBase];
    const child = spawn(binaryPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout = keepTail(stdout + chunk);
    });
    child.stderr.on("data", (chunk: string) => {
      stderr = keepTail(stderr + chunk);
    });

    const exitCode = await new Promise<number>((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code) => resolve(code ?? 1));
    });

    if (exitCode !== 0) {
      throw new Error(`whisper-cli exited with code ${exitCode}. ${stderr.trim() || stdout.trim()}`);
    }

    const transcriptPath = `${outputBase}.txt`;
    if (existsSync(transcriptPath)) return readFileSync(transcriptPath, "utf8");
    return stdout;
  } finally {
    rmSync(workingDirectory, { recursive: true, force: true });
  }
}

function cleanTranscript(raw: string): string {
  return raw
    .replace(/^\s*\[[^\]]+\]\s*/gm, "")
    .replace(/\s+/g, " ")
    .trim();
}

function keepTail(value: string): string {
  const maximumLength = 128_000;
  return value.length > maximumLength ? value.slice(-maximumLength) : value;
}

async function captureForegroundBundleId(): Promise<string | null> {
  if (process.platform !== "darwin" || !systemPreferences.isTrustedAccessibilityClient(false)) return null;
  const script = [
    'tell application "System Events"',
    "set activeProcess to first application process whose frontmost is true",
    "return bundle identifier of activeProcess",
    "end tell",
  ];
  const result = await runProcess("/usr/bin/osascript", script.flatMap((line) => ["-e", line]));
  return result.code === 0 ? result.stdout.trim() || null : null;
}

async function pasteIntoApp(bundleId: string): Promise<void> {
  const script = [
    "on run argv",
    "set targetBundle to item 1 of argv",
    'tell application "System Events"',
    "set frontmost of first application process whose bundle identifier is targetBundle to true",
    "delay 0.18",
    'keystroke "v" using command down',
    "end tell",
    "end run",
  ];
  const result = await runProcess("/usr/bin/osascript", [...script.flatMap((line) => ["-e", line]), bundleId]);
  if (result.code !== 0) throw new Error(result.stderr.trim() || "AppleScript could not send Command+V.");
}

async function runProcess(command: string, args: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
  const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => { stdout += chunk; });
  child.stderr.on("data", (chunk: string) => { stderr += chunk; });
  const code = await new Promise<number>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (exitCode) => resolve(exitCode ?? 1));
  });
  return { code, stdout, stderr };
}

function collectMetrics(): PerformanceMetrics {
  const totalWorkingSetMb = latestProcessMetrics.reduce((sum, metric) => sum + metric.workingSetMb, 0);
  const realTimeFactor = lastTranscriptionMs !== null && lastAudioDurationMs
    ? lastTranscriptionMs / lastAudioDurationMs
    : null;

  return {
    phase,
    totalWorkingSetMb: roundOne(totalWorkingSetMb),
    peakWorkingSetMb: roundOne(peakWorkingSetMb),
    processCount: latestProcessMetrics.length,
    sampledAt: lastMemorySampleAt,
    memoryMeasurement: process.platform === "darwin" ? "Physical footprint" : "RSS",
    processes: latestProcessMetrics,
    lastTranscriptionMs,
    lastAudioDurationMs,
    realTimeFactor: realTimeFactor === null ? null : Math.round(realTimeFactor * 100) / 100,
  };
}

function startMemorySampler(): void {
  void sampleMemoryNow();
  scheduleMemorySample();
}

function scheduleMemorySample(delayMs = phase === "transcribing" ? 200 : 1_000): void {
  if (isQuitting) return;
  if (memorySampleTimer) clearTimeout(memorySampleTimer);
  memorySampleTimer = setTimeout(async () => {
    memorySampleTimer = null;
    await sampleMemoryNow();
    scheduleMemorySample();
  }, delayMs);
}

async function sampleMemoryNow(): Promise<void> {
  if (memorySampleInFlight) return;
  memorySampleInFlight = true;
  try {
    const electronMetrics = app.getAppMetrics();
    const processTree = await getProcessTree(process.pid);
    const physicalFootprints = process.platform === "darwin"
      ? await getPhysicalFootprints(processTree.map((snapshot) => snapshot.pid))
      : new Map<number, PhysicalFootprintSnapshot>();
    const electronByPid = new Map(electronMetrics.map((metric) => [metric.pid, metric]));
    const snapshots = processTree.length > 0
      ? processTree
      : electronMetrics.map((metric) => ({
          pid: metric.pid,
          parentPid: metric.pid === process.pid ? process.ppid : process.pid,
          rssKb: metric.memory.workingSetSize,
          command: metric.name ?? metric.type,
          depth: metric.pid === process.pid ? 0 : 1,
        }));

    const activePids = new Set<number>();
    latestProcessMetrics = snapshots.map((snapshot) => {
      activePids.add(snapshot.pid);
      const electronMetric = electronByPid.get(snapshot.pid);
      const name = processDisplayName(snapshot, electronMetric);
      const footprint = physicalFootprints.get(snapshot.pid);
      const workingSetMb = footprint ? footprint.currentBytes / 1024 / 1024 : snapshot.rssKb / 1024;
      const previousPeak = processPeakWorkingSetMb.get(snapshot.pid);
      const reportedPeakMb = footprint ? footprint.peakBytes / 1024 / 1024 : workingSetMb;
      const peakMb = previousPeak?.name === name
        ? Math.max(previousPeak.peakMb, reportedPeakMb, workingSetMb)
        : Math.max(reportedPeakMb, workingSetMb);
      processPeakWorkingSetMb.set(snapshot.pid, { name, peakMb });
      return {
        pid: snapshot.pid,
        parentPid: snapshot.parentPid,
        depth: snapshot.depth,
        name,
        type: electronMetric?.type ?? (snapshot.pid === process.pid ? "Browser" : "Child"),
        workingSetMb: roundOne(workingSetMb),
        peakWorkingSetMb: roundOne(peakMb),
      };
    });

    for (const pid of processPeakWorkingSetMb.keys()) {
      if (!activePids.has(pid)) processPeakWorkingSetMb.delete(pid);
    }

    const totalWorkingSetMb = latestProcessMetrics.reduce((sum, metric) => sum + metric.workingSetMb, 0);
    peakWorkingSetMb = Math.max(peakWorkingSetMb, totalWorkingSetMb);
    lastMemorySampleAt = Date.now();
  } finally {
    memorySampleInFlight = false;
  }
}

async function getPhysicalFootprints(pids: number[]): Promise<Map<number, PhysicalFootprintSnapshot>> {
  if (pids.length === 0) return new Map();

  try {
    const helperPath = app.isPackaged
      ? path.join(process.resourcesPath, "process-memory")
      : path.join(__dirname, "process-memory");
    const result = await runProcess(helperPath, pids.map(String));
    return result.code === 0 ? parsePhysicalFootprints(result.stdout) : new Map();
  } catch {
    return new Map();
  }
}

async function getProcessTree(rootPid: number): Promise<ProcessTreeSnapshot[]> {
  if (process.platform === "win32") return [];

  try {
    const child = spawn("/bin/ps", ["-axo", "pid=,ppid=,rss=,comm="], { stdio: ["ignore", "pipe", "ignore"] });
    const samplerPid = child.pid;
    let stdout = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => { stdout += chunk; });
    const code = await new Promise<number>((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (exitCode) => resolve(exitCode ?? 1));
    });
    if (code !== 0) return [];
    return selectProcessTree(
      parseProcessTable(stdout),
      rootPid,
      samplerPid === undefined ? new Set() : new Set([samplerPid]),
    );
  } catch {
    return [];
  }
}

function processDisplayName(snapshot: ProcessTreeSnapshot, electronMetric?: Electron.ProcessMetric): string {
  if (electronMetric?.type === "Browser") return "Open Wisper";
  if (electronMetric?.type === "Tab") return "Renderer";
  if (electronMetric?.type === "GPU") return "GPU";
  if (electronMetric?.name) return electronMetric.name;
  if (electronMetric?.serviceName) return electronMetric.serviceName;
  if (electronMetric) return electronMetric.type;
  return path.basename(snapshot.command) || snapshot.command;
}

function roundOne(value: number): number {
  return Math.round(value * 10) / 10;
}

function isExecutable(filePath: string): boolean {
  try {
    accessSync(filePath, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function isReadableFile(filePath: string): boolean {
  try {
    accessSync(filePath, constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

if (!primaryInstance) {
  app.quit();
} else {
  app.on("second-instance", showWindow);
  app.whenReady().then(async () => {
    settingsStore = new SettingsStore();
    session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback, details) => {
      const mediaDetails = details as { mediaTypes?: string[] };
      const isAudioRequest = permission === "media" && mediaDetails.mediaTypes?.includes("audio");
      callback(Boolean(isAudioRequest));
    });
    session.defaultSession.setPermissionCheckHandler((_webContents, permission, _requestingOrigin, details) => {
      return permission === "media" && details.mediaType === "audio";
    });
    installIpcHandlers();
    startMemorySampler();
    mainWindow = createWindow();
    tray = createTray();
    app.dock?.hide();

    if (!registerShortcut(settingsStore.get().shortcut)) {
      settingsStore.update({ shortcut: "CommandOrControl+Shift+Space" });
    }

    const microphoneStatus = process.platform === "darwin"
      ? systemPreferences.getMediaAccessStatus("microphone")
      : "unknown";
    if (microphoneStatus === "not-determined" && process.platform === "darwin") {
      await systemPreferences.askForMediaAccess("microphone");
    }

    mainWindow.once("ready-to-show", () => mainWindow?.show());
  });

  app.on("activate", showWindow);
  app.on("before-quit", () => {
    isQuitting = true;
    if (memorySampleTimer) clearTimeout(memorySampleTimer);
    globalShortcut.unregisterAll();
  });
  app.on("window-all-closed", () => {
    // A menu-bar app intentionally stays alive after its control window closes.
  });
}

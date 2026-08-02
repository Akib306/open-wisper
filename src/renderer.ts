import { encodePcm16Wav, mergeFloat32Chunks, resampleLinear, rmsLevel } from "./audio";
import { AppPhase, OpenWisperApi, RecordingSource, Settings } from "./shared";

declare global {
  interface Window {
    openWisper: OpenWisperApi;
  }
}

const api = window.openWisper;
const TARGET_SAMPLE_RATE = 16_000;

const elements = {
  statusDot: byId("status-dot"),
  statusLabel: byId("status-label"),
  statusMessage: byId("status-message"),
  recordButton: byId<HTMLButtonElement>("record-button"),
  recordButtonLabel: byId("record-button-label"),
  levelRing: byId<HTMLElement>("level-ring"),
  shortcutLabel: byId("shortcut-label"),
  transcript: byId<HTMLTextAreaElement>("transcript"),
  copyButton: byId<HTMLButtonElement>("copy-button"),
  pasteButton: byId<HTMLButtonElement>("paste-button"),
  memoryMetric: byId("memory-metric"),
  peakMetric: byId("peak-metric"),
  speedMetric: byId("speed-metric"),
  processMetric: byId("process-metric"),
  engineBadge: byId("engine-badge"),
  binaryPath: byId<HTMLInputElement>("binary-path"),
  modelPath: byId<HTMLInputElement>("model-path"),
  chooseBinary: byId<HTMLButtonElement>("choose-binary"),
  chooseModel: byId<HTMLButtonElement>("choose-model"),
  setupButton: byId<HTMLButtonElement>("setup-button"),
  autoPaste: byId<HTMLInputElement>("auto-paste"),
  launchAtLogin: byId<HTMLInputElement>("launch-at-login"),
  toast: byId("toast"),
};

let settings: Settings;
let recorder: PcmRecorder | null = null;
let phase: AppPhase = "idle";
let currentSource: RecordingSource = "window";
let toastTimer: number | null = null;

class PcmRecorder {
  private stream: MediaStream | null = null;
  private context: AudioContext | null = null;
  private source: MediaStreamAudioSourceNode | null = null;
  private processor: ScriptProcessorNode | null = null;
  private chunks: Float32Array[] = [];
  private sampleRate = 48_000;

  async start(onLevel: (level: number) => void): Promise<void> {
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
      video: false,
    });
    this.context = new AudioContext({ latencyHint: "interactive" });
    await this.context.resume();
    this.sampleRate = this.context.sampleRate;
    this.source = this.context.createMediaStreamSource(this.stream);
    this.processor = this.context.createScriptProcessor(4096, 1, 1);
    this.processor.onaudioprocess = (event) => {
      const input = event.inputBuffer.getChannelData(0);
      const copy = new Float32Array(input.length);
      copy.set(input);
      this.chunks.push(copy);
      onLevel(rmsLevel(copy));
    };
    this.source.connect(this.processor);
    this.processor.connect(this.context.destination);
  }

  async stop(): Promise<{ wavData: ArrayBuffer; durationMs: number }> {
    if (!this.context || !this.processor || !this.source || !this.stream) {
      throw new Error("The recorder is not running.");
    }

    this.processor.onaudioprocess = null;
    this.source.disconnect();
    this.processor.disconnect();
    this.stream.getTracks().forEach((track) => track.stop());
    await this.context.close();

    const merged = mergeFloat32Chunks(this.chunks);
    const durationMs = merged.length / this.sampleRate * 1000;
    const resampled = resampleLinear(merged, this.sampleRate, TARGET_SAMPLE_RATE);
    this.reset();
    return { wavData: encodePcm16Wav(resampled, TARGET_SAMPLE_RATE), durationMs };
  }

  async cancel(): Promise<void> {
    if (this.processor) this.processor.onaudioprocess = null;
    this.source?.disconnect();
    this.processor?.disconnect();
    this.stream?.getTracks().forEach((track) => track.stop());
    if (this.context && this.context.state !== "closed") await this.context.close();
    this.reset();
  }

  private reset(): void {
    this.stream = null;
    this.context = null;
    this.source = null;
    this.processor = null;
    this.chunks = [];
  }
}

async function initialize(): Promise<void> {
  settings = await api.getSettings();
  applySettings(settings);
  bindEvents();
  await refreshRuntimeStatus();
  await updateMetrics();
  window.setInterval(() => void updateMetrics(), 1_000);
}

function bindEvents(): void {
  elements.recordButton.addEventListener("click", () => void toggleRecording("window"));
  elements.copyButton.addEventListener("click", () => void deliverCurrentText(false));
  elements.pasteButton.addEventListener("click", () => void deliverCurrentText(true));

  elements.chooseBinary.addEventListener("click", async () => {
    const selected = await api.chooseWhisperBinary();
    if (selected) await saveSettings({ whisperBinaryPath: selected });
  });
  elements.chooseModel.addEventListener("click", async () => {
    const selected = await api.chooseModel();
    if (selected) await saveSettings({ modelPath: selected });
  });
  elements.setupButton.addEventListener("click", async () => {
    await api.revealSetupScript();
    showToast("Run pnpm setup:whisper in Terminal, then reopen the app.");
  });
  elements.autoPaste.addEventListener("change", () => void saveSettings({ autoPaste: elements.autoPaste.checked }));
  elements.launchAtLogin.addEventListener("change", () => void saveSettings({ launchAtLogin: elements.launchAtLogin.checked }));

  api.onCommand(({ action, source }) => {
    if (action === "toggle") void toggleRecording(source);
    if (action === "start" && phase !== "recording") void startRecording(source);
    if (action === "stop" && phase === "recording") void stopRecording();
  });
  api.onSettingsChanged((updated) => {
    settings = updated;
    applySettings(updated);
    void refreshRuntimeStatus();
  });
}

async function toggleRecording(source: RecordingSource): Promise<void> {
  if (phase === "recording") {
    await stopRecording();
  } else if (phase !== "transcribing") {
    await startRecording(source);
  }
}

async function startRecording(source: RecordingSource): Promise<void> {
  const runtime = await api.getRuntimeStatus();
  if (!runtime.binaryReady || !runtime.modelReady) {
    setUiPhase("error", "Finish engine setup before recording.");
    showToast("whisper.cpp is not ready. Open Engine setup below.");
    document.querySelector("details")?.setAttribute("open", "");
    return;
  }

  currentSource = source;
  recorder = new PcmRecorder();
  try {
    await api.prepareRecording(source);
    await recorder.start((level) => {
      elements.levelRing.style.setProperty("--level", String(Math.max(0.08, level)));
    });
    setUiPhase("recording", "Listening locally — press again to stop");
  } catch (error) {
    await recorder.cancel();
    recorder = null;
    setUiPhase("error", friendlyMediaError(error));
  }
}

async function stopRecording(): Promise<void> {
  if (!recorder) return;
  const activeRecorder = recorder;
  recorder = null;
  setUiPhase("transcribing", "Turning speech into text on this Mac…");
  elements.levelRing.style.setProperty("--level", "0.08");

  try {
    const recording = await activeRecorder.stop();
    if (recording.durationMs < 350) throw new Error("That recording was too short. Try speaking for at least half a second.");
    const result = await api.transcribe(recording.wavData, recording.durationMs);
    if (!result.text) throw new Error("No speech was detected. Try again a little closer to the microphone.");

    elements.transcript.value = result.text;
    const delivery = await api.deliverText(result.text, currentSource !== "window");
    if (delivery.pasted) {
      setUiPhase("success", `Pasted in ${(result.elapsedMs / 1000).toFixed(1)} seconds`);
    } else {
      setUiPhase("success", `Copied in ${(result.elapsedMs / 1000).toFixed(1)} seconds`);
      if (delivery.reason) showToast(delivery.reason);
    }
  } catch (error) {
    setUiPhase("error", errorMessage(error));
  }
}

async function deliverCurrentText(allowAutoPaste: boolean): Promise<void> {
  const result = await api.deliverText(elements.transcript.value, allowAutoPaste);
  showToast(result.pasted ? "Pasted into the target app." : result.reason ?? "Copied to clipboard.");
}

async function saveSettings(patch: Partial<Settings>): Promise<void> {
  try {
    settings = await api.updateSettings(patch);
    applySettings(settings);
    await refreshRuntimeStatus();
  } catch (error) {
    showToast(errorMessage(error));
  }
}

function applySettings(updated: Settings): void {
  elements.binaryPath.value = updated.whisperBinaryPath;
  elements.modelPath.value = updated.modelPath;
  elements.autoPaste.checked = updated.autoPaste;
  elements.launchAtLogin.checked = updated.launchAtLogin;
  elements.shortcutLabel.textContent = formatShortcut(updated.shortcut);
}

async function refreshRuntimeStatus(): Promise<void> {
  const status = await api.getRuntimeStatus();
  const ready = status.binaryReady && status.modelReady;
  elements.engineBadge.classList.toggle("ready", ready);
  elements.engineBadge.textContent = ready ? "Engine ready" : "Setup needed";
  elements.recordButton.disabled = phase === "transcribing";
}

function setUiPhase(nextPhase: AppPhase, message?: string): void {
  phase = nextPhase;
  void api.setPhase(nextPhase);
  document.body.dataset.phase = nextPhase;
  elements.statusDot.className = `status-dot ${nextPhase}`;
  elements.statusLabel.textContent = phaseLabel(nextPhase);
  elements.statusMessage.textContent = message ?? phaseMessage(nextPhase);
  elements.recordButtonLabel.textContent = nextPhase === "recording" ? "Stop" : nextPhase === "transcribing" ? "Working" : "Record";
  elements.recordButton.disabled = nextPhase === "transcribing";
  elements.copyButton.disabled = !elements.transcript.value.trim();
  elements.pasteButton.disabled = !elements.transcript.value.trim();
}

async function updateMetrics(): Promise<void> {
  try {
    const metrics = await api.getMetrics();
    elements.memoryMetric.textContent = `${metrics.totalWorkingSetMb.toFixed(1)} MB`;
    elements.peakMetric.textContent = `${metrics.peakWorkingSetMb.toFixed(1)} MB`;
    elements.processMetric.textContent = String(metrics.processCount);
    elements.speedMetric.textContent = metrics.realTimeFactor === null ? "—" : `${metrics.realTimeFactor.toFixed(2)}×`;
  } catch {
    // The window may be shutting down between timer ticks.
  }
}

function phaseLabel(value: AppPhase): string {
  return {
    idle: "Ready to dictate",
    recording: "Recording",
    transcribing: "Transcribing",
    success: "Done",
    error: "Needs attention",
  }[value];
}

function phaseMessage(value: AppPhase): string {
  return {
    idle: "Your audio and transcript stay on this Mac.",
    recording: "Listening locally — press again to stop",
    transcribing: "Turning speech into text on this Mac…",
    success: "Your transcript is ready.",
    error: "Something went wrong.",
  }[value];
}

function formatShortcut(shortcut: string): string {
  return shortcut
    .replace("CommandOrControl", "⌘")
    .replace("Command", "⌘")
    .replace("Shift", "⇧")
    .replace("Alt", "⌥")
    .replace(/\+/g, " ");
}

function friendlyMediaError(error: unknown): string {
  const message = errorMessage(error);
  if (/denied|permission|notallowed/i.test(message)) {
    return "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone.";
  }
  return message;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function showToast(message: string): void {
  elements.toast.textContent = message;
  elements.toast.classList.add("visible");
  if (toastTimer !== null) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => elements.toast.classList.remove("visible"), 4_500);
}

function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing #${id}`);
  return element as T;
}

void initialize().catch((error) => setUiPhase("error", errorMessage(error)));

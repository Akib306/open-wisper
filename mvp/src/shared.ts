export type AppPhase = "idle" | "recording" | "transcribing" | "success" | "error";

export type RecordingSource = "window" | "shortcut" | "tray";

export interface Settings {
  whisperBinaryPath: string;
  modelPath: string;
  autoPaste: boolean;
  launchAtLogin: boolean;
  shortcut: string;
}

export interface RuntimeStatus {
  binaryReady: boolean;
  modelReady: boolean;
  platform: string;
  packaged: boolean;
}

export interface PerformanceMetrics {
  phase: AppPhase;
  totalWorkingSetMb: number;
  peakWorkingSetMb: number;
  processCount: number;
  sampledAt: number;
  memoryMeasurement: "Physical footprint" | "RSS";
  processes: ProcessMemoryMetric[];
  lastTranscriptionMs: number | null;
  lastAudioDurationMs: number | null;
  realTimeFactor: number | null;
}

export interface ProcessMemoryMetric {
  pid: number;
  parentPid: number;
  depth: number;
  name: string;
  type: string;
  workingSetMb: number;
  peakWorkingSetMb: number;
}

export interface TranscriptionResult {
  text: string;
  elapsedMs: number;
  audioDurationMs: number;
}

export interface DeliveryResult {
  copied: boolean;
  pasted: boolean;
  reason?: string;
}

export interface CommandPayload {
  action: "toggle" | "start" | "stop";
  source: RecordingSource;
}

export interface OpenWisperApi {
  getSettings(): Promise<Settings>;
  updateSettings(patch: Partial<Settings>): Promise<Settings>;
  getRuntimeStatus(): Promise<RuntimeStatus>;
  chooseWhisperBinary(): Promise<string | null>;
  chooseModel(): Promise<string | null>;
  revealSetupScript(): Promise<void>;
  prepareRecording(source: RecordingSource): Promise<void>;
  setPhase(phase: AppPhase): Promise<void>;
  transcribe(wavData: ArrayBuffer, audioDurationMs: number): Promise<TranscriptionResult>;
  deliverText(text: string, allowAutoPaste: boolean): Promise<DeliveryResult>;
  getMetrics(): Promise<PerformanceMetrics>;
  onCommand(callback: (payload: CommandPayload) => void): () => void;
  onSettingsChanged(callback: (settings: Settings) => void): () => void;
}

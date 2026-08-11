import { contextBridge, ipcRenderer } from "electron";
import { AppPhase, CommandPayload, OpenWisperApi, RecordingSource, Settings } from "./shared";

const api: OpenWisperApi = {
  getSettings: () => ipcRenderer.invoke("settings:get"),
  updateSettings: (patch: Partial<Settings>) => ipcRenderer.invoke("settings:update", patch),
  getRuntimeStatus: () => ipcRenderer.invoke("runtime:status"),
  chooseWhisperBinary: () => ipcRenderer.invoke("runtime:choose-binary"),
  chooseModel: () => ipcRenderer.invoke("runtime:choose-model"),
  revealSetupScript: () => ipcRenderer.invoke("runtime:reveal-setup"),
  prepareRecording: (source: RecordingSource) => ipcRenderer.invoke("recording:prepare", source),
  setPhase: (phase: AppPhase) => ipcRenderer.invoke("phase:set", phase),
  transcribe: (wavData: ArrayBuffer, audioDurationMs: number) => ipcRenderer.invoke("transcribe", wavData, audioDurationMs),
  deliverText: (text: string, allowAutoPaste: boolean) => ipcRenderer.invoke("text:deliver", text, allowAutoPaste),
  getMetrics: () => ipcRenderer.invoke("metrics:get"),
  onCommand: (callback: (payload: CommandPayload) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, payload: CommandPayload) => callback(payload);
    ipcRenderer.on("recording-command", listener);
    return () => ipcRenderer.removeListener("recording-command", listener);
  },
  onSettingsChanged: (callback: (settings: Settings) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, settings: Settings) => callback(settings);
    ipcRenderer.on("settings-changed", listener);
    return () => ipcRenderer.removeListener("settings-changed", listener);
  },
};

contextBridge.exposeInMainWorld("openWisper", api);

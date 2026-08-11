export interface SystemProcessSnapshot {
  pid: number;
  parentPid: number;
  rssKb: number;
  command: string;
}

export interface ProcessTreeSnapshot extends SystemProcessSnapshot {
  depth: number;
}

export interface PhysicalFootprintSnapshot {
  currentBytes: number;
  peakBytes: number;
}

export function parseProcessTable(output: string): SystemProcessSnapshot[] {
  const snapshots: SystemProcessSnapshot[] = [];

  for (const line of output.split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+?)\s*$/);
    if (!match) continue;

    const [, pid, parentPid, rssKb, command] = match;
    snapshots.push({
      pid: Number(pid),
      parentPid: Number(parentPid),
      rssKb: Number(rssKb),
      command,
    });
  }

  return snapshots;
}

export function selectProcessTree(
  snapshots: SystemProcessSnapshot[],
  rootPid: number,
  excludedPids: ReadonlySet<number> = new Set(),
): ProcessTreeSnapshot[] {
  const childrenByParent = new Map<number, SystemProcessSnapshot[]>();
  for (const snapshot of snapshots) {
    const children = childrenByParent.get(snapshot.parentPid) ?? [];
    children.push(snapshot);
    childrenByParent.set(snapshot.parentPid, children);
  }
  for (const children of childrenByParent.values()) {
    children.sort((left, right) => left.pid - right.pid);
  }

  const result: ProcessTreeSnapshot[] = [];
  const visited = new Set<number>();

  function visit(snapshot: SystemProcessSnapshot, depth: number): void {
    if (visited.has(snapshot.pid) || excludedPids.has(snapshot.pid)) return;
    visited.add(snapshot.pid);
    result.push({ ...snapshot, depth });
    for (const child of childrenByParent.get(snapshot.pid) ?? []) visit(child, depth + 1);
  }

  const root = snapshots.find((snapshot) => snapshot.pid === rootPid);
  if (root) visit(root, 0);
  return result;
}

export function parsePhysicalFootprints(output: string): Map<number, PhysicalFootprintSnapshot> {
  const footprints = new Map<number, PhysicalFootprintSnapshot>();
  for (const line of output.split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s*$/);
    if (!match) continue;
    footprints.set(Number(match[1]), {
      currentBytes: Number(match[2]),
      peakBytes: Number(match[3]),
    });
  }
  return footprints;
}

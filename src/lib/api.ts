const getBaseUrl = (): string => {
  const saved = localStorage.getItem('pi-dashboard-settings');
  if (saved) {
    try {
      const settings = JSON.parse(saved);
      return `http://${settings.piIp}:${settings.apiPort}`;
    } catch {}
  }
  return `http://${window.location.hostname}:8585`;
};

export interface SystemStatus {
  cpu: number;
  temp: number;
  ramUsed: number;
  ramTotal: number;
  diskUsed: number;
  diskTotal: number;
  uptime: string;
  services: {
    [key: string]: { online: boolean; version: string };
  };
}

export interface UpdateResult {
  app: string;
  status: 'idle' | 'updating' | 'success' | 'error';
  message?: string;
  timestamp?: string;
}

export async function fetchSystemStatus(): Promise<SystemStatus> {
  const res = await fetch(`${getBaseUrl()}/api/status`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch status');
  return res.json();
}

export async function triggerUpdate(app: string): Promise<UpdateResult> {
  const res = await fetch(`${getBaseUrl()}/api/update/${app}`, {
    method: 'POST',
    signal: AbortSignal.timeout(120000),
  });
  if (!res.ok) throw new Error('Failed to trigger update');
  return res.json();
}

export async function fetchUpdateStatus(app: string): Promise<UpdateResult> {
  const res = await fetch(`${getBaseUrl()}/api/update-status/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch update status');
  return res.json();
}

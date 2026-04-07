import { loadSettings } from '@/components/Settings';

/** Build base URL for the dashboard-level API (global settings) */
const getDashboardBaseUrl = (): string => {
  const saved = localStorage.getItem('pi-dashboard-settings');
  if (saved) {
    try {
      const settings = JSON.parse(saved);
      return `http://${settings.piIp}:${settings.apiPort}`;
    } catch {}
  }
  return `http://${window.location.hostname}:8585`;
};

/** Build base URL for a specific service (per-service host/apiPort) */
const getServiceBaseUrl = (appKey: string): string => {
  try {
    const settings = loadSettings();
    const svc = settings.services.find(s => s.key === appKey);
    if (svc) {
      return `http://${svc.host}:${svc.apiPort}`;
    }
  } catch {}
  return getDashboardBaseUrl();
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
    [key: string]: { online: boolean; version: string; installed: boolean; cpu: number; ramMb: number; cpuCore: number };
  };
}

export interface UpdateResult {
  app: string;
  status: 'idle' | 'updating' | 'success' | 'error';
  message?: string;
  timestamp?: string;
}

export interface InstallResult {
  app: string;
  status: 'idle' | 'installing' | 'success' | 'error';
  message?: string;
  progress?: string;
  timestamp?: string;
}

export interface ServiceActionResult {
  app: string;
  action: 'start' | 'stop' | 'restart';
  status: 'success' | 'error';
  message?: string;
}

export async function fetchSystemStatus(): Promise<SystemStatus> {
  const res = await fetch(`${getDashboardBaseUrl()}/api/status`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch status');
  return res.json();
}

export async function triggerUpdate(app: string): Promise<UpdateResult> {
  const base = app === 'dashboard' ? getDashboardBaseUrl() : getServiceBaseUrl(app);
  const res = await fetch(`${base}/api/update/${app}`, {
    method: 'POST',
    signal: AbortSignal.timeout(120000),
  });
  if (!res.ok) throw new Error('Failed to trigger update');
  return res.json();
}

export async function fetchUpdateStatus(app: string): Promise<UpdateResult> {
  const base = app === 'dashboard' ? getDashboardBaseUrl() : getServiceBaseUrl(app);
  const res = await fetch(`${base}/api/update-status/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch update status');
  return res.json();
}

export async function triggerInstall(app: string): Promise<InstallResult> {
  const base = getServiceBaseUrl(app);
  const res = await fetch(`${base}/api/install/${app}`, {
    method: 'POST',
    signal: AbortSignal.timeout(300000),
  });
  if (!res.ok) throw new Error('Failed to trigger install');
  return res.json();
}

export async function fetchInstallStatus(app: string): Promise<InstallResult> {
  const base = getServiceBaseUrl(app);
  const res = await fetch(`${base}/api/install-status/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch install status');
  return res.json();
}

export async function serviceAction(app: string, action: 'start' | 'stop' | 'restart'): Promise<ServiceActionResult> {
  const base = getServiceBaseUrl(app);
  const res = await fetch(`${base}/api/service/${app}/${action}`, {
    method: 'POST',
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`Failed to ${action} service`);
  return res.json();
}

export async function fetchLogs(app: string, type: 'update' | 'install' = 'update'): Promise<string> {
  const endpoint = type === 'install' ? 'install-log' : 'update-log';
  const base = app === 'dashboard' ? getDashboardBaseUrl() : getServiceBaseUrl(app);
  const res = await fetch(`${base}/api/${endpoint}/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) return 'Inga loggar tillgängliga';
  const data = await res.json();
  return data.log || 'Tom logg';
}
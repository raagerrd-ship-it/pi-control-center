import { loadSettings } from '@/components/Settings';

const getBaseUrl = (): string => {
  try {
    const settings = loadSettings();
    return `http://${settings.piIp}:${settings.apiPort}`;
  } catch {}
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

export async function triggerInstall(app: string): Promise<InstallResult> {
  const res = await fetch(`${getBaseUrl()}/api/install/${app}`, {
    method: 'POST',
    signal: AbortSignal.timeout(300000),
  });
  if (!res.ok) throw new Error('Failed to trigger install');
  return res.json();
}

export async function fetchInstallStatus(app: string): Promise<InstallResult> {
  const res = await fetch(`${getBaseUrl()}/api/install-status/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch install status');
  return res.json();
}

export async function serviceAction(app: string, action: 'start' | 'stop' | 'restart'): Promise<ServiceActionResult> {
  const res = await fetch(`${getBaseUrl()}/api/service/${app}/${action}`, {
    method: 'POST',
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`Failed to ${action} service`);
  return res.json();
}

export async function fetchLogs(app: string, type: 'update' | 'install' = 'update'): Promise<string> {
  const endpoint = type === 'install' ? 'install-log' : 'update-log';
  const res = await fetch(`${getBaseUrl()}/api/${endpoint}/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) return 'Inga loggar tillgängliga';
  const data = await res.json();
  return data.log || 'Tom logg';
}
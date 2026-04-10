const API_PORT = '8585';


const getBaseUrl = (): string => {
  return `http://${window.location.hostname}:${API_PORT}`;
};

export interface SystemStatus {
  cpu: number;
  temp: number;
  ramUsed: number;
  ramTotal: number;
  diskUsed: number;
  diskTotal: number;
  uptime: string;
  dashboardCpu: number;
  dashboardRamMb: number;
  commit: string;
  branch: string;
  services: {
    [key: string]: { online: boolean; version: string; installed: boolean; cpu: number; ramMb: number; cpuCore: number; port?: number };
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
  elapsed?: string;
  timestamp?: string;
}

export interface ServiceActionResult {
  app: string;
  action: 'start' | 'stop' | 'restart';
  status: 'success' | 'error';
  message?: string;
}

export interface VersionInfo {
  local: string;
  remote: string;
  hasUpdate: boolean;
}

export type VersionMap = Record<string, VersionInfo>;

export interface ServiceDefinition {
  key: string;
  name: string;
  type?: 'static' | 'node';
  entrypoint?: string;
  repo: string;
  releaseUrl?: string;
  installDir: string;
  installScript: string;
  updateScript: string;
  uninstallScript: string;
  service: string;
}

export interface UninstallResult {
  app: string;
  status: 'success' | 'error';
  message?: string;
}

export async function fetchPing(): Promise<boolean> {
  const res = await fetch(`${getBaseUrl()}/api/ping`, { signal: AbortSignal.timeout(2000) });
  return res.ok;
}

export async function fetchSystemStatus(): Promise<SystemStatus> {
  const res = await fetch(`${getBaseUrl()}/api/status`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch status');
  return res.json();
}

export async function fetchAvailableServices(): Promise<ServiceDefinition[]> {
  const res = await fetch(`${getBaseUrl()}/api/available-services`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch available services');
  return res.json();
}

export async function fetchVersions(): Promise<VersionMap> {
  const res = await fetch(`${getBaseUrl()}/api/versions`, { signal: AbortSignal.timeout(15000) });
  if (!res.ok) throw new Error('Failed to fetch versions');
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

export async function triggerInstall(app: string, port: number, core: number): Promise<InstallResult> {
  const res = await fetch(`${getBaseUrl()}/api/install/${app}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ port, core }),
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

export async function triggerUninstall(app: string): Promise<UninstallResult> {
  const res = await fetch(`${getBaseUrl()}/api/uninstall/${app}`, {
    method: 'POST',
    signal: AbortSignal.timeout(60000),
  });
  if (!res.ok) throw new Error('Failed to trigger uninstall');
  return res.json();
}

export async function fetchLogs(app: string, type: 'update' | 'install' | 'service' = 'update'): Promise<string> {
  const endpoint = type === 'install' ? 'install-log' : type === 'service' ? 'service-log' : 'update-log';
  const res = await fetch(`${getBaseUrl()}/api/${endpoint}/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) return 'Inga loggar tillgängliga';
  const data = await res.json();
  return data.log || 'Tom logg';
}

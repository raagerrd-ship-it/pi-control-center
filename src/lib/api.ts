const API_PORT = '8585';


const getBaseUrl = (): string => {
  return `http://${window.location.hostname}:${API_PORT}`;
};

export interface ComponentStatus {
  online: boolean;
  version: string;
  cpu: number;
  ramMb: number;
  service: string;
  port?: number;
  cpuCore?: number;
}

export interface HealthStatus {
  status: 'ok' | 'degraded' | 'error' | 'unreachable' | 'offline' | 'unknown';
  uptime?: number;
  memoryRss?: number;
}

export interface ServiceStatus {
  online: boolean;
  version: string;
  installed: boolean;
  cpu: number;
  ramMb: number;
  cpuCore: number;
  port?: number;
  /** Health check data from engine's /api/health */
  health?: HealthStatus;
  /** Present when the service uses engine/ui components */
  components?: {
    engine?: ComponentStatus;
    ui?: ComponentStatus;
  };
}

export interface SystemStatus {
  cpu: number;
  cpuCores?: number[];
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
    [key: string]: ServiceStatus;
  };
}

export interface UpdateResult {
  app: string;
  status: 'idle' | 'updating' | 'success' | 'error';
  message?: string;
  progress?: string;
  elapsed?: string;
  timestamp?: string;
}

export interface InstallResult {
  app: string;
  status: 'idle' | 'installing' | 'success' | 'error';
  message?: string;
  progress?: string;
  elapsed?: string;
  timestamp?: string;
  step?: number;
  totalSteps?: number;
  percent?: number;
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

export interface ComponentDefinition {
  type: 'static' | 'node';
  entrypoint?: string;
  service: string;
  alwaysOn?: boolean;
}

export interface ServiceDefinition {
  key: string;
  name: string;
  /** Legacy single-service fields */
  type?: 'static' | 'node';
  entrypoint?: string;
  service?: string;
  /** New component-based structure */
  components?: {
    engine?: ComponentDefinition;
    ui?: ComponentDefinition;
  };
  repo: string;
  releaseUrl?: string;
  installDir: string;
  installScript: string;
  updateScript: string;
  uninstallScript: string;
}

/** Check if a service definition uses the new components format */
export function hasComponents(def: ServiceDefinition): boolean {
  return !!(def.components && (def.components.engine || def.components.ui));
}

/** Get the primary service name (legacy or engine component) */
export function getPrimaryService(def: ServiceDefinition): string {
  if (def.components?.engine) return def.components.engine.service;
  return def.service || def.key;
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

export async function fetchSystemStatus(timeoutMs = 4000): Promise<SystemStatus> {
  const res = await fetch(`${getBaseUrl()}/api/status`, { signal: AbortSignal.timeout(timeoutMs) });
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

export async function fetchVersion(app: string): Promise<VersionInfo> {
  const res = await fetch(`${getBaseUrl()}/api/version/${app}`, { signal: AbortSignal.timeout(15000) });
  if (!res.ok) throw new Error('Failed to fetch version');
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
    body: JSON.stringify({ core }),
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

export async function serviceAction(app: string, action: 'start' | 'stop' | 'restart', component?: 'engine' | 'ui'): Promise<ServiceActionResult> {
  const url = component
    ? `${getBaseUrl()}/api/service/${app}/${action}?component=${component}`
    : `${getBaseUrl()}/api/service/${app}/${action}`;
  const res = await fetch(url, {
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

export interface FactoryResetResult {
  status: 'resetting' | 'success' | 'error' | 'idle';
  phase?: string;
  timestamp?: string;
}

export async function triggerFactoryReset(): Promise<FactoryResetResult> {
  const res = await fetch(`${getBaseUrl()}/api/factory-reset`, {
    method: 'POST',
    signal: AbortSignal.timeout(120000),
  });
  if (!res.ok) throw new Error('Failed to trigger factory reset');
  return res.json();
}

export async function triggerPiReset(): Promise<FactoryResetResult> {
  const res = await fetch(`${getBaseUrl()}/api/pi-reset`, {
    method: 'POST',
    signal: AbortSignal.timeout(120000),
  });
  if (!res.ok) throw new Error('Failed to trigger Pi reset');
  return res.json();
}

export interface MemoryLimitResult {
  app: string;
  limitMb: number;
  raw?: string;
  status?: string;
}

export async function fetchMemoryLimit(app: string): Promise<MemoryLimitResult> {
  const res = await fetch(`${getBaseUrl()}/api/memory-limit/${app}`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch memory limit');
  return res.json();
}

export async function setMemoryLimit(app: string, limitMb: number): Promise<MemoryLimitResult> {
  const res = await fetch(`${getBaseUrl()}/api/memory-limit/${app}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ limitMb }),
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw new Error('Failed to set memory limit');
  return res.json();
}

export async function fetchFactoryResetStatus(): Promise<FactoryResetResult> {
  const res = await fetch(`${getBaseUrl()}/api/factory-reset-status`, { signal: AbortSignal.timeout(4000) });
  if (!res.ok) throw new Error('Failed to fetch reset status');
  return res.json();
}

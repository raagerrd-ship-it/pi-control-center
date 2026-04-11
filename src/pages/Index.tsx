import { useState, useCallback, useEffect, useMemo } from 'react';
import { SystemMonitor } from '@/components/SystemMonitor';
import { PullToRefresh } from '@/components/PullToRefresh';
import { CoreCard } from '@/components/CoreCard';
import { ActivityLog } from '@/components/ActivityLog';
import { Settings, loadSettings, type DashboardSettings } from '@/components/Settings';
import { useSystemStatus } from '@/hooks/useSystemStatus';
import { useServiceUpdate } from '@/hooks/useServiceUpdate';
import { useActivityLog } from '@/hooks/useActivityLog';
import {
  triggerUpdate, fetchUpdateStatus, fetchVersions, fetchAvailableServices,
  type UpdateResult, type VersionMap, type ServiceDefinition, fetchLogs,
} from '@/lib/api';

const CORES = [1, 2, 3];

const Index = () => {
  const [settings, setSettings] = useState<DashboardSettings>(loadSettings);
  const { status, error, loading, connection, refresh } = useSystemStatus();
  const { addEntry } = useActivityLog();

  const [availableServices, setAvailableServices] = useState<ServiceDefinition[]>([]);
  const [dashboardUpdate, setDashboardUpdate] = useState<UpdateResult | null>(null);
  const [versions, setVersions] = useState<VersionMap | null>(null);
  const [checkingVersions, setCheckingVersions] = useState(false);

  const serviceNames = useMemo(() => {
    const map: Record<string, string> = {};
    availableServices.forEach(s => { map[s.key] = s.name; });
    return map;
  }, [availableServices]);

  const { updates, startUpdate, installs, startInstall, uninstalls, startUninstall, actions, runServiceAction } = useServiceUpdate(serviceNames);

  useEffect(() => {
    fetchAvailableServices().then(setAvailableServices).catch(() => {});
    handleCheckVersions();
  }, []);

  const usedPorts = useMemo(() => {
    if (!status?.services) return [];
    return Object.values(status.services)
      .filter(s => s.installed && s.port)
      .map(s => s.port!);
  }, [status]);

  // Map: core index → service key installed on that core
  const coreServiceMap = useMemo(() => {
    const map: Record<number, string> = {};
    if (!status?.services) return map;
    Object.entries(status.services).forEach(([key, svc]) => {
      if (svc.installed && svc.cpuCore >= 1) {
        map[svc.cpuCore] = key;
      }
    });
    return map;
  }, [status]);

  // Services not installed on any core
  const uninstalledServices = useMemo(() => {
    const installedKeys = new Set(Object.values(coreServiceMap));
    return availableServices.filter(s => !installedKeys.has(s.key));
  }, [availableServices, coreServiceMap]);

  const handleCheckVersions = useCallback(async () => {
    setCheckingVersions(true);
    try {
      const v = await fetchVersions();
      setVersions(v);
    } catch {} finally {
      setCheckingVersions(false);
    }
  }, []);

  const handleDashboardUpdate = useCallback(async () => {
    addEntry('DASHBOARD', 'Uppdatering startad', 'info');
    setDashboardUpdate({ app: 'dashboard', status: 'updating' });
    try { await triggerUpdate('dashboard'); } catch {}
    let retries = 0;
    let lastLogLine = '';
    const poll = async () => {
      try {
        const result = await fetchUpdateStatus('dashboard');
        setDashboardUpdate(result);
        if (result.status === 'updating') {
          retries = 0;
          try {
            const log = await fetchLogs('dashboard', 'update');
            if (log && log !== 'Tom logg' && log !== 'Inga loggar tillgängliga') {
              const latest = log.split('\n').filter(Boolean).slice(-1)[0] || '';
              if (latest && latest !== lastLogLine) {
                lastLogLine = latest;
                addEntry('DASHBOARD', latest, 'info');
              }
            }
          } catch {}
          setTimeout(poll, 3000);
        }
        else if (result.status === 'success') { addEntry('DASHBOARD', 'Uppdaterad', 'success'); }
        else if (result.status === 'error') {
          addEntry('DASHBOARD', `Uppdatering misslyckades: ${result.message || 'okänt fel'}`, 'error');
          try {
            const log = await fetchLogs('dashboard', 'update');
            if (log && log !== 'Tom logg' && log !== 'Inga loggar tillgängliga') {
              const lastLines = log.split('\n').filter(Boolean).slice(-5).join(' | ');
              if (lastLines) addEntry('DASHBOARD', `Logg: ${lastLines}`, 'error');
            }
          } catch {}
        }
      } catch {
        retries++;
        if (retries < 60) { setTimeout(poll, 3000); }
        else {
          addEntry('DASHBOARD', 'Tappade anslutning under uppdatering', 'error');
          setDashboardUpdate({ app: 'dashboard', status: 'error', message: 'Lost connection to API' });
        }
      }
    };
    setTimeout(poll, 3000);
  }, [addEntry]);

  const handleServiceAction = useCallback(async (app: string, action: 'start' | 'stop' | 'restart') => {
    await runServiceAction(app, action);
    setTimeout(() => {
      void refresh();
    }, 800);
  }, [refresh, runServiceAction]);

  const isUpdatingDashboard = dashboardUpdate?.status === 'updating';
  const dashboardVersion = versions?.dashboard;
  const updatesAvailable = versions ? Object.values(versions).some(v => v.hasUpdate) : false;

  return (
    <PullToRefresh onRefresh={refresh}>
      <div className="bg-background p-3 sm:p-6 max-w-2xl mx-auto overflow-hidden">
        <header className="flex items-center justify-between mb-6">
          <div>
            <h1 className="font-mono text-lg font-bold tracking-tight">Pi Dashboard</h1>
            <p className="font-mono text-xs text-muted-foreground">{window.location.hostname}</p>
          </div>
          <Settings onSave={setSettings} />
        </header>

        <section className="mb-6">
          <SystemMonitor
            status={status} error={error} loading={loading}
            connection={connection}
            dashboardVersion={dashboardVersion}
            dashboardUpdate={dashboardUpdate}
            isUpdatingDashboard={isUpdatingDashboard}
            checkingVersions={checkingVersions}
            updatesAvailable={updatesAvailable}
            onCheckVersions={handleCheckVersions}
            onDashboardUpdate={handleDashboardUpdate}
          />
        </section>

        <section>
          <h2 className="font-mono text-xs uppercase tracking-wider text-muted-foreground mb-3">
            Tjänster
          </h2>
          <div className="grid gap-3 grid-cols-1 sm:grid-cols-3">
            {CORES.map(coreIdx => {
              const serviceKey = coreServiceMap[coreIdx];
              const def = availableServices.find(s => s.key === serviceKey);
              const svcStatus = serviceKey ? status?.services?.[serviceKey] : undefined;

              const service = def && svcStatus ? {
                definition: def,
                online: svcStatus.online,
                installed: svcStatus.installed,
                version: svcStatus.version ?? '—',
                cpu: svcStatus.cpu,
                ramMb: svcStatus.ramMb,
                port: svcStatus.port,
                versionInfo: versions?.[serviceKey],
                updateStatus: updates[serviceKey],
                installStatus: installs[serviceKey],
                actionStatus: actions[serviceKey],
              } : undefined;

              return (
                <CoreCard
                  key={coreIdx}
                  coreIndex={coreIdx}
                  service={service}
                  availableServices={uninstalledServices}
                  allInstalls={installs}
                  usedPorts={usedPorts}
                  status={status}
                  onUpdate={startUpdate}
                  onInstall={startInstall}
                  onUninstall={startUninstall}
                  onServiceAction={handleServiceAction}
                />
              );
            })}
          </div>
        </section>

        <ActivityLog />

        <footer className="mt-8 pb-4 text-center font-mono text-[10px] text-muted-foreground/40">
          {settings.deviceLabel || 'Pi Zero 2'} · {window.location.hostname}
        </footer>
      </div>
    </PullToRefresh>
  );
};

export default Index;

import { useState, useCallback, useEffect, useMemo } from 'react';
import { SystemMonitor } from '@/components/SystemMonitor';
import { PullToRefresh } from '@/components/PullToRefresh';
import { CoreCard } from '@/components/CoreCard';
import { OrphanedServiceCard } from '@/components/OrphanedServiceCard';
import { ActivityLog } from '@/components/ActivityLog';
import { Settings, loadSettings, type DashboardSettings } from '@/components/Settings';
import { useSystemStatus } from '@/hooks/useSystemStatus';
import { useServiceUpdate } from '@/hooks/useServiceUpdate';
import { useActivityLog } from '@/hooks/useActivityLog';
import {
  triggerUpdate, fetchUpdateStatus, fetchVersions, fetchVersion, fetchAvailableServices,
  fetchMemoryLimit, triggerReboot,
  type UpdateResult, type VersionMap, type ServiceDefinition, fetchLogs,
} from '@/lib/api';

const CORES = [1, 2, 3];

const Index = () => {
  const [settings, setSettings] = useState<DashboardSettings>(loadSettings);
  const { addEntry } = useActivityLog();

  const [availableServices, setAvailableServices] = useState<ServiceDefinition[]>([]);
  const [dashboardUpdate, setDashboardUpdate] = useState<UpdateResult | null>(null);
  const [versions, setVersions] = useState<VersionMap | null>(null);
  const [checkingVersions, setCheckingVersions] = useState(false);
  const [memLimits, setMemLimits] = useState<Record<string, number>>({});
  const [rebooting, setRebooting] = useState(false);

  const serviceNames = useMemo(() => {
    const map: Record<string, string> = {};
    availableServices.forEach(s => { map[s.key] = s.name; });
    return map;
  }, [availableServices]);

  const { updates, startUpdate, installs, startInstall, uninstalls, startUninstall, actions, runServiceAction } = useServiceUpdate(serviceNames);

  // Determine if any operation is active (install/update/dashboard update)
  const isBusy = useMemo(() => {
    const hasActiveUpdate = Object.values(updates).some(u => u.status === 'updating');
    const hasActiveInstall = Object.values(installs).some(i => i.status === 'installing');
    const isDashUpdating = dashboardUpdate?.status === 'updating';
    return hasActiveUpdate || hasActiveInstall || isDashUpdating;
  }, [updates, installs, dashboardUpdate]);

  const { status, error, loading, connection, refresh } = useSystemStatus(isBusy);

  useEffect(() => {
    fetchAvailableServices().then(setAvailableServices).catch(() => {});
    handleCheckVersions();
  }, []);

  // Fetch memory limits for installed services and discard stale limits
  useEffect(() => {
    if (!status?.services) {
      setMemLimits({});
      return;
    }

    const installedKeys = Object.entries(status.services)
      .filter(([, svc]) => svc.installed)
      .map(([key]) => key);
    const installedSet = new Set(installedKeys);

    setMemLimits(prev => {
      const next = Object.fromEntries(
        Object.entries(prev).filter(([key]) => installedSet.has(key)),
      );
      return Object.keys(next).length === Object.keys(prev).length ? prev : next;
    });

    const budget = 330;
    const defaultPerApp = installedKeys.length > 0
      ? Math.floor(budget / installedKeys.length)
      : Math.floor(budget / 3);

    setMemLimits(prev => {
      const missing = installedKeys.filter(k => prev[k] == null);
      if (missing.length === 0) return prev;
      missing.forEach(key => {
        const cachedLimit = status.services[key]?.memoryMaxMb;
        if (cachedLimit) {
          setMemLimits(p => ({ ...p, [key]: cachedLimit }));
        } else {
          fetchMemoryLimit(key)
            .then(r => setMemLimits(p => ({ ...p, [key]: r.limitMb })))
            .catch(() => setMemLimits(p => ({ ...p, [key]: defaultPerApp })));
        }
      });
      return prev;
    });
  }, [status?.ramTotal, status?.services]);

  const handleMemLimitChange = useCallback((app: string, mb: number) => {
    setMemLimits(prev => ({ ...prev, [app]: mb }));
  }, []);

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

  // Orphaned: installed but no valid core assignment (cpuCore < 1)
  const orphanedServices = useMemo(() => {
    if (!status?.services) return [] as Array<{ key: string; status: typeof status.services[string] }>;
    return Object.entries(status.services)
      .filter(([, svc]) => svc.installed && svc.cpuCore < 1)
      .map(([key, svcStatus]) => ({ key, status: svcStatus }));
  }, [status]);

  // Services not installed on any core (and not orphaned)
  const uninstalledServices = useMemo(() => {
    const claimedKeys = new Set([
      ...Object.values(coreServiceMap),
      ...orphanedServices.map(o => o.key),
    ]);
    return availableServices.filter(s => !claimedKeys.has(s.key));
  }, [availableServices, coreServiceMap, orphanedServices]);

  const handleCheckVersions = useCallback(async () => {
    setCheckingVersions(true);
    try {
      const v = await fetchVersions();
      setVersions(v);
    } catch {} finally {
      setCheckingVersions(false);
    }
  }, []);

  const handleCheckVersion = useCallback(async (app: string) => {
    const v = await fetchVersion(app);
    setVersions(prev => ({ ...prev, [app]: v }));
  }, []);

  const handleDashboardUpdate = useCallback(async () => {
    const commitBefore = status?.commit || '';
    addEntry('DASHBOARD', 'Uppdatering startad', 'info');
    setDashboardUpdate({ app: 'dashboard', status: 'updating', progress: 'Initierar uppdatering...' });
    try { await triggerUpdate('dashboard'); } catch {}
    let retries = 0;
    let lostContact = false;
    let lastLogLine = '';
    const poll = async () => {
      try {
        const result = await fetchUpdateStatus('dashboard');
        if (lostContact) {
          addEntry('DASHBOARD', 'Åter kontakt — fortsätter spåra uppdatering', 'success');
          lostContact = false;
        }
        if (result.status === 'updating') {
          retries = 0;
          let latestProgress = result.progress || result.message || '';
          try {
            const log = await fetchLogs('dashboard', 'update');
            if (log && log !== 'Tom logg' && log !== 'Inga loggar tillgängliga') {
              const latest = log.split('\n').filter(Boolean).slice(-1)[0] || '';
              if (latest && latest !== lastLogLine) {
                lastLogLine = latest;
                addEntry('DASHBOARD', latest, 'info');
              }
              if (latest) latestProgress = latest;
            }
          } catch {}
          setDashboardUpdate({
            ...result,
            progress: latestProgress || lastLogLine || 'Uppdatering pågår...',
          });
          setTimeout(poll, 3000);
        }
        else if (result.status === 'success') {
          addEntry('DASHBOARD', 'Uppdaterad', 'success');
          setDashboardUpdate({
            ...result,
            status: 'success',
            message: result.message || 'Dashboard uppdaterad',
          });
          void refresh();
          void handleCheckVersions();
        }
        else if (result.status === 'error') {
          addEntry('DASHBOARD', `Uppdatering misslyckades: ${result.message || 'okänt fel'}`, 'error');
          setDashboardUpdate({
            ...result,
            status: 'error',
            message: result.message || 'Uppdatering misslyckades',
          });
          try {
            const log = await fetchLogs('dashboard', 'update');
            if (log && log !== 'Tom logg' && log !== 'Inga loggar tillgängliga') {
              const lastLines = log.split('\n').filter(Boolean).slice(-5).join(' | ');
              if (lastLines) addEntry('DASHBOARD', `Logg: ${lastLines}`, 'error');
            }
          } catch {}
        }
        // status is idle — API restarted and lost state. Check if commit changed.
        else if (result.status === 'idle' && commitBefore) {
          try {
            const freshStatus = await import('@/lib/api').then(m => m.fetchSystemStatus());
            if (freshStatus.commit && freshStatus.commit !== commitBefore) {
              addEntry('DASHBOARD', `Uppdaterad (${commitBefore.slice(0, 7)} → ${freshStatus.commit.slice(0, 7)})`, 'success');
              setDashboardUpdate({ app: 'dashboard', status: 'success' });
              void refresh();
              void handleCheckVersions();
            } else {
              // Same commit — might still be building, retry a few more times
              if (retries < 10) {
                retries++;
                setDashboardUpdate(prev => ({
                  app: 'dashboard',
                  status: 'updating',
                  progress: prev?.progress || 'Startar om dashboard-tjänsten...',
                  elapsed: prev?.elapsed,
                }));
                setTimeout(poll, 5000);
              }
              else {
                addEntry('DASHBOARD', 'Uppdatering slutförd (ingen ny version hittades)', 'info');
                setDashboardUpdate({ app: 'dashboard', status: 'success' });
              }
            }
          } catch {
            if (retries < 10) {
              retries++;
              setDashboardUpdate(prev => ({
                app: 'dashboard',
                status: 'updating',
                progress: prev?.progress || 'Väntar på att dashboard kommer tillbaka...',
                elapsed: prev?.elapsed,
              }));
              setTimeout(poll, 5000);
            }
          }
        }
      } catch {
        retries++;
        if (!lostContact && retries >= 3) {
          lostContact = true;
          addEntry('DASHBOARD', 'Pi upptagen — inväntar status...', 'info');
        }
        if (retries < 60) {
          setDashboardUpdate(prev => ({
            app: 'dashboard',
            status: 'updating',
            progress: 'Pi upptagen — väntar på status från API:t...',
            elapsed: prev?.elapsed,
          }));
          setTimeout(poll, 3000);
        }
        else {
          // Last resort: check if commit changed
          try {
            const freshStatus = await import('@/lib/api').then(m => m.fetchSystemStatus());
            if (freshStatus.commit && freshStatus.commit !== commitBefore) {
              addEntry('DASHBOARD', `Uppdaterad (${commitBefore.slice(0, 7)} → ${freshStatus.commit.slice(0, 7)})`, 'success');
              setDashboardUpdate({ app: 'dashboard', status: 'success' });
              void refresh();
              return;
            }
          } catch {}
          addEntry('DASHBOARD', 'Tappade anslutning under uppdatering', 'error');
          setDashboardUpdate({ app: 'dashboard', status: 'error', message: 'Lost connection to API' });
        }
      }
    };
    setTimeout(poll, 3000);
  }, [addEntry, status?.commit, refresh, handleCheckVersions]);

  const handleServiceAction = useCallback(async (app: string, action: 'start' | 'stop' | 'restart', component?: 'engine' | 'ui') => {
    await runServiceAction(app, action, component);
    setTimeout(() => {
      void refresh();
    }, 800);
  }, [refresh, runServiceAction]);

  const handleReboot = useCallback(async () => {
    setRebooting(true);
    addEntry('SYSTEM', 'Startar om Pi...', 'info');
    try { await triggerReboot(); } catch {}
  }, [addEntry]);

  const isUpdatingDashboard = dashboardUpdate?.status === 'updating';
  const dashboardVersion = versions?.dashboard;
  const updatesAvailable = versions ? Object.values(versions).some(v => v.hasUpdate) : false;

  return (
    <PullToRefresh onRefresh={refresh}>
      <div className="bg-background p-3 sm:p-6 max-w-2xl mx-auto overflow-hidden">
        <header className="flex items-center justify-between mb-6">
          <div>
            <h1 className="font-mono text-lg font-bold tracking-tight">Pi Control Center</h1>
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
            rebooting={rebooting}
            onReboot={handleReboot}
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
                memoryMaxMb: svcStatus.memoryMaxMb,
                memoryLevel: svcStatus.memoryLevel,
                memoryProfile: svcStatus.memoryProfile,
                port: svcStatus.port,
                versionInfo: versions?.[serviceKey],
                updateStatus: updates[serviceKey],
                installStatus: installs[serviceKey],
                actionStatus: actions[serviceKey],
                components: svcStatus.components,
                health: svcStatus.health,
              } : undefined;

              // Calculate other installed services' allocated RAM
              const otherAllocated = Object.entries(memLimits)
                .filter(([key]) => key !== serviceKey && status?.services?.[key]?.installed)
                .reduce((sum, [, mb]) => sum + mb, 0);

              return (
                <CoreCard
                  key={coreIdx}
                  coreIndex={coreIdx}
                  service={service}
                  availableServices={uninstalledServices}
                  allInstalls={installs}
                  memLimitMb={serviceKey ? (memLimits[serviceKey] ?? null) : null}
                  otherAllocatedMb={otherAllocated}
                  ramBudgetMb={330}
                  onMemLimitChange={handleMemLimitChange}
                  onUpdate={startUpdate}
                  onCheckVersion={handleCheckVersion}
                  onInstall={startInstall}
                  onUninstall={startUninstall}
                  onServiceAction={handleServiceAction}
                />
              );
            })}
          </div>
        </section>

        {orphanedServices.length > 0 && (
          <section className="mt-6">
            <h2 className="font-mono text-xs uppercase tracking-wider text-[hsl(var(--status-warning))] mb-3 flex items-center gap-1.5">
              Föräldralösa tjänster
              <span className="text-muted-foreground/50 normal-case tracking-normal">
                — installerade men felaktigt registrerade
              </span>
            </h2>
            <div className="grid gap-3 grid-cols-1 sm:grid-cols-3">
              {orphanedServices.map(({ key, status: svcStatus }) => (
                <OrphanedServiceCard
                  key={key}
                  serviceKey={key}
                  displayName={serviceNames[key] || key}
                  status={svcStatus}
                  uninstallStatus={uninstalls[key]}
                  onUninstall={startUninstall}
                />
              ))}
            </div>
          </section>
        )}

        <ActivityLog />

        <footer className="mt-8 pb-4 text-center font-mono text-[10px] text-muted-foreground/40 space-y-0.5">
          <div>{settings.deviceLabel || 'Pi Zero 2'} · {window.location.hostname}</div>
          {status?.commit && (
            <div>
              {status.branch || 'main'}@{status.commit.slice(0, 7)}
            </div>
          )}
        </footer>
      </div>
    </PullToRefresh>
  );
};

export default Index;

import { useState, useCallback } from 'react';
import { RefreshCw, CheckCircle2, AlertCircle } from 'lucide-react';
import { SystemMonitor } from '@/components/SystemMonitor';
import { PullToRefresh } from '@/components/PullToRefresh';
import { ServiceCard } from '@/components/ServiceCard';
import { ConnectionLog } from '@/components/ConnectionLog';
import { Settings, loadSettings, type DashboardSettings } from '@/components/Settings';
import { useSystemStatus } from '@/hooks/useSystemStatus';
import { useServiceUpdate } from '@/hooks/useServiceUpdate';
import { Button } from '@/components/ui/button';
import { triggerUpdate, fetchUpdateStatus, fetchVersions, type UpdateResult, type VersionMap } from '@/lib/api';

const Index = () => {
  const [settings, setSettings] = useState<DashboardSettings>(loadSettings);
  const { status, error, loading, logs, refresh } = useSystemStatus();
  const { updates, startUpdate, installs, startInstall, actions, runServiceAction } = useServiceUpdate();
  const [dashboardUpdate, setDashboardUpdate] = useState<UpdateResult | null>(null);
  const [versions, setVersions] = useState<VersionMap | null>(null);
  const [checkingVersions, setCheckingVersions] = useState(false);

  const handleCheckVersions = useCallback(async () => {
    setCheckingVersions(true);
    try {
      const v = await fetchVersions();
      setVersions(v);
    } catch {
      // silently fail
    } finally {
      setCheckingVersions(false);
    }
  }, []);

  const handleDashboardUpdate = useCallback(async () => {
    setDashboardUpdate({ app: 'dashboard', status: 'updating' });
    try {
      await triggerUpdate('dashboard');
      const poll = async () => {
        const result = await fetchUpdateStatus('dashboard');
        setDashboardUpdate(result);
        if (result.status === 'updating') {
          setTimeout(poll, 3000);
        }
      };
      setTimeout(poll, 3000);
    } catch (e) {
      setDashboardUpdate({
        app: 'dashboard',
        status: 'error',
        message: e instanceof Error ? e.message : 'Update failed',
      });
    }
  }, []);

  const isUpdatingDashboard = dashboardUpdate?.status === 'updating';
  const dashboardVersion = versions?.dashboard;
  const updatesAvailable = versions ? Object.values(versions).some(v => v.hasUpdate) : false;

  return (
    <PullToRefresh onRefresh={refresh}>
      <div className="bg-background p-4 sm:p-6 max-w-2xl mx-auto">
      <header className="flex items-center justify-between mb-6">
        <div>
          <h1 className="font-mono text-lg font-bold tracking-tight">Pi Dashboard</h1>
          <p className="font-mono text-xs text-muted-foreground">
            {settings.piIp}
          </p>
        </div>
        <div className="flex items-center gap-1">
          <Settings onSave={setSettings} />
        </div>
      </header>

      <section className="mb-6">
        <SystemMonitor status={status} error={error} loading={loading} />
      </section>

      <section>
        <h2 className="font-mono text-xs uppercase tracking-wider text-muted-foreground mb-3">
          Tjänster
        </h2>
        <div className="grid gap-3 grid-cols-1 sm:grid-cols-2">
          {settings.services.map(svc => {
            const svcStatus = status?.services?.[svc.key];
            return (
              <ServiceCard
                key={svc.key}
                name={svc.name}
                appKey={svc.key}
                port={svc.port}
                piIp={settings.piIp}
                online={svcStatus?.online ?? false}
                installed={svcStatus?.installed ?? false}
                version={svcStatus?.version ?? '—'}
                cpu={svcStatus?.cpu ?? 0}
                ramMb={svcStatus?.ramMb ?? 0}
                cpuCore={svcStatus?.cpuCore ?? -1}
                deviceLabel={settings.deviceLabel}
                versionInfo={versions?.[svc.key]}
                updateStatus={updates[svc.key]}
                installStatus={installs[svc.key]}
                actionStatus={actions[svc.key]}
                onUpdate={startUpdate}
                onInstall={startInstall}
                onServiceAction={runServiceAction}
              />
            );
          })}
        </div>
      </section>

      {/* Dashboard section */}
      <section className="mt-6">
        <div className="flex items-center justify-between mb-3">
          <h2 className="font-mono text-xs uppercase tracking-wider text-muted-foreground">
            System
          </h2>
          <div className="relative">
            <Button
              variant="ghost"
              size="sm"
              className={`font-mono text-[11px] gap-1 h-6 px-2 ${updatesAvailable ? 'text-[hsl(var(--status-warning))]' : 'text-muted-foreground hover:text-foreground'}`}
              disabled={checkingVersions}
              onClick={handleCheckVersions}
            >
              <RefreshCw className={`h-3 w-3 ${checkingVersions ? 'animate-spin' : ''}`} />
              {checkingVersions ? 'Söker...' : 'Sök uppdateringar'}
            </Button>
            {updatesAvailable && (
              <span className="absolute -top-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-[hsl(var(--status-warning))] border-2 border-background" />
            )}
          </div>
        </div>
        <div className={`rounded-lg border p-3.5 flex flex-col gap-2.5 ${dashboardVersion?.hasUpdate ? 'border-[hsl(var(--status-warning)/0.3)] bg-[hsl(var(--status-warning)/0.05)]' : 'bg-card'}`}>
          <div className="flex items-center gap-2">
            <div className="h-2 w-2 rounded-full bg-[hsl(var(--status-online))]" />
            <h3 className="font-medium text-sm leading-none">Dashboard + Nginx</h3>
          </div>

          <div className="flex items-center gap-2 font-mono text-[11px] text-muted-foreground">
            <span className="inline-flex items-center gap-1 rounded bg-secondary px-1.5 py-0.5">
              <span className="text-foreground text-[10px]">Core 0</span>
            </span>
            <span>{status?.dashboardCpu?.toFixed(1) ?? '0.0'}%</span>
            <span className="text-border">·</span>
            <span>{status?.dashboardRamMb ?? 7}MB</span>
          </div>

          <div className={`flex items-center justify-between rounded px-2 py-1 text-[10px] font-mono ${dashboardVersion?.hasUpdate ? 'bg-[hsl(var(--status-warning)/0.08)] border border-[hsl(var(--status-warning)/0.25)]' : 'bg-secondary/30'}`}>
            <span className="text-muted-foreground">Version {dashboardVersion?.local || '—'}</span>
            {dashboardVersion?.hasUpdate ? (
              <span className="text-[hsl(var(--status-warning))]">Ny version</span>
            ) : (
              <span className="text-muted-foreground/50">✓</span>
            )}
          </div>

          {dashboardUpdate?.status === 'success' && (
            <span className="flex items-center gap-1 text-[11px] text-[hsl(var(--status-online))] font-mono">
              <CheckCircle2 className="h-3 w-3" /> Klar
            </span>
          )}
          {dashboardUpdate?.status === 'error' && (
            <span className="flex items-center gap-1 text-[11px] text-destructive font-mono" title={dashboardUpdate.message}>
              <AlertCircle className="h-3 w-3" /> Misslyckades
            </span>
          )}

          <div className="flex items-center gap-1">
            <Button
              variant={dashboardVersion?.hasUpdate ? 'default' : 'secondary'}
              size="sm"
              className="font-mono text-[11px] gap-1 h-7 px-2 flex-1"
              disabled={isUpdatingDashboard}
              onClick={handleDashboardUpdate}
            >
              <RefreshCw className={`h-3 w-3 ${isUpdatingDashboard ? 'animate-spin' : ''}`} />
              {isUpdatingDashboard ? 'Uppdaterar...' : 'Uppdatera'}
            </Button>
          </div>
        </div>
      </section>

      <ConnectionLog logs={logs} />

      <footer className="mt-8 pb-4 text-center font-mono text-[10px] text-muted-foreground/40">
        {settings.deviceLabel || 'Pi Zero 2'} · {settings.piIp}
      </footer>
     </div>
    </PullToRefresh>
  );
};

export default Index;

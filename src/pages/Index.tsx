import { useState } from 'react';
import { RefreshCw, CheckCircle2, AlertCircle } from 'lucide-react';
import { SystemMonitor } from '@/components/SystemMonitor';
import { ServiceCard } from '@/components/ServiceCard';
import { Settings, loadSettings, type DashboardSettings } from '@/components/Settings';
import { useSystemStatus } from '@/hooks/useSystemStatus';
import { useServiceUpdate } from '@/hooks/useServiceUpdate';
import { Button } from '@/components/ui/button';
import { triggerUpdate, type UpdateResult } from '@/lib/api';

const Index = () => {
  const [settings, setSettings] = useState<DashboardSettings>(loadSettings);
  const { status, error, loading } = useSystemStatus();
  const { updates, startUpdate, installs, startInstall, actions, runServiceAction } = useServiceUpdate();
  const [dashboardUpdate, setDashboardUpdate] = useState<UpdateResult | null>(null);

  const handleDashboardUpdate = async () => {
    setDashboardUpdate({ app: 'dashboard', status: 'updating' });
    try {
      const result = await triggerUpdate('dashboard');
      setDashboardUpdate(result);
    } catch (e) {
      setDashboardUpdate({
        app: 'dashboard',
        status: 'error',
        message: e instanceof Error ? e.message : 'Update failed',
      });
    }
  };

  const isUpdatingDashboard = dashboardUpdate?.status === 'updating';

  return (
    <div className="min-h-screen bg-background p-4 sm:p-6 max-w-2xl mx-auto">
      <header className="flex items-center justify-between mb-6">
        <div>
          <h1 className="font-mono text-lg font-bold tracking-tight">Pi Dashboard</h1>
          <p className="font-mono text-xs text-muted-foreground">{settings.piIp}</p>
        </div>
        <div className="flex items-center gap-1">
          <Button
            variant="ghost"
            size="sm"
            className="font-mono text-xs gap-1.5 text-muted-foreground hover:text-foreground"
            disabled={isUpdatingDashboard}
            onClick={handleDashboardUpdate}
            title="Uppdatera dashboarden"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${isUpdatingDashboard ? 'animate-spin' : ''}`} />
            {isUpdatingDashboard ? 'Uppdaterar...' : 'v.update'}
          </Button>
          {dashboardUpdate?.status === 'success' && (
            <CheckCircle2 className="h-3.5 w-3.5 text-[hsl(var(--status-online))]" />
          )}
          {dashboardUpdate?.status === 'error' && (
            <AlertCircle className="h-3.5 w-3.5 text-destructive" title={dashboardUpdate.message} />
          )}
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
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
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

      <footer className="mt-8 text-center font-mono text-[10px] text-muted-foreground">
        Manuell uppdatering · API: :{settings.apiPort}
      </footer>
    </div>
  );
};

export default Index;

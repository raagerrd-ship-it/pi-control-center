import { useState } from 'react';
import { SystemMonitor } from '@/components/SystemMonitor';
import { ServiceCard } from '@/components/ServiceCard';
import { Settings, loadSettings, type DashboardSettings } from '@/components/Settings';
import { useSystemStatus } from '@/hooks/useSystemStatus';
import { useServiceUpdate } from '@/hooks/useServiceUpdate';

const Index = () => {
  const [settings, setSettings] = useState<DashboardSettings>(loadSettings);
  const { status, error, loading } = useSystemStatus();
  const { updates, startUpdate, installs, startInstall, actions, runServiceAction } = useServiceUpdate();

  return (
    <div className="min-h-screen bg-background p-4 sm:p-6 max-w-2xl mx-auto">
      <header className="flex items-center justify-between mb-6">
        <div>
          <h1 className="font-mono text-lg font-bold tracking-tight">Pi Dashboard</h1>
          <p className="font-mono text-xs text-muted-foreground">{settings.piIp}</p>
        </div>
        <Settings onSave={setSettings} />
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
        Auto-update: varje timme · API: :{settings.apiPort}
      </footer>
    </div>
  );
};

export default Index;

import { Cpu, Thermometer, HardDrive, Clock, MemoryStick, RefreshCw, CheckCircle2, AlertCircle } from 'lucide-react';
import { Progress } from '@/components/ui/progress';
import { Button } from '@/components/ui/button';
import type { SystemStatus, UpdateResult, VersionInfo } from '@/lib/api';

interface GaugeProps {
  icon: React.ReactNode;
  label: string;
  value: string;
  percent?: number;
  warning?: boolean;
}

function Gauge({ icon, label, value, percent, warning }: GaugeProps) {
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-2 text-muted-foreground">
        {icon}
        <span className="text-xs uppercase tracking-wider">{label}</span>
      </div>
      <span className={`font-mono text-lg font-semibold ${warning ? 'text-destructive' : 'text-foreground'}`}>
        {value}
      </span>
      {percent !== undefined && (
        <Progress value={percent} className="h-1.5 bg-secondary" />
      )}
    </div>
  );
}

interface SystemMonitorProps {
  status: SystemStatus | null;
  error: string | null;
  loading: boolean;
  dashboardVersion?: VersionInfo;
  dashboardUpdate: UpdateResult | null;
  isUpdatingDashboard: boolean;
  checkingVersions: boolean;
  updatesAvailable: boolean;
  onCheckVersions: () => void;
  onDashboardUpdate: () => void;
}

export function SystemMonitor({
  status, error, loading,
  dashboardVersion, dashboardUpdate, isUpdatingDashboard,
  checkingVersions, updatesAvailable,
  onCheckVersions, onDashboardUpdate,
}: SystemMonitorProps) {
  if (loading) {
    return (
      <div className="rounded-lg border bg-card p-4">
        <p className="font-mono text-sm text-muted-foreground animate-pulse">Ansluter till Pi...</p>
      </div>
    );
  }

  if (error || !status) {
    return (
      <div className="rounded-lg border border-destructive/30 bg-card p-4">
        <p className="font-mono text-sm text-destructive">⚠ {error === 'Failed to fetch' ? 'Kunde inte ansluta' : error || 'Ingen data'}</p>
        <p className="font-mono text-xs text-muted-foreground mt-1">Kontrollera IP och port i inställningar</p>
      </div>
    );
  }

  const ramPercent = Math.round((status.ramUsed / status.ramTotal) * 100);
  const diskPercent = Math.round((status.diskUsed / status.diskTotal) * 100);

  return (
    <div className={`rounded-lg border p-4 flex flex-col gap-4 ${dashboardVersion?.hasUpdate ? 'border-[hsl(var(--status-warning)/0.3)] bg-[hsl(var(--status-warning)/0.05)]' : 'bg-card'}`}>
      {/* System gauges */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-5">
        <Gauge icon={<Cpu className="h-3.5 w-3.5" />} label="CPU" value={`${status.cpu}%`} percent={status.cpu} warning={status.cpu > 85} />
        <Gauge icon={<Thermometer className="h-3.5 w-3.5" />} label="Temp" value={`${status.temp}°C`} percent={Math.min(status.temp, 85)} warning={status.temp > 70} />
        <Gauge icon={<MemoryStick className="h-3.5 w-3.5" />} label="RAM" value={`${status.ramUsed}/${status.ramTotal} MB`} percent={ramPercent} warning={ramPercent > 85} />
        <Gauge icon={<HardDrive className="h-3.5 w-3.5" />} label="Disk" value={`${status.diskUsed}/${status.diskTotal} GB`} percent={diskPercent} warning={diskPercent > 90} />
        <Gauge icon={<Clock className="h-3.5 w-3.5" />} label="Drifttid" value={status.uptime} />
      </div>

      {/* Separator */}
      <div className="border-t border-border" />

      {/* Dashboard row */}
      <div className="flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="h-2 w-2 rounded-full bg-[hsl(var(--status-online))]" />
            <span className="font-medium text-sm leading-none">Dashboard + Nginx</span>
            <span className="font-mono text-[11px] text-muted-foreground inline-flex items-center gap-1 rounded bg-secondary px-1.5 py-0.5">
              <span className="text-foreground text-[10px]">Core 0</span>
            </span>
            <span className="font-mono text-[11px] text-muted-foreground">{status.dashboardCpu?.toFixed(1) ?? '0.0'}%</span>
            <span className="font-mono text-[11px] text-border">·</span>
            <span className="font-mono text-[11px] text-muted-foreground">{status.dashboardRamMb ?? 7}MB</span>
          </div>
          <div className="relative">
            <Button
              variant="ghost"
              size="sm"
              className={`font-mono text-[11px] gap-1 h-6 px-2 ${updatesAvailable ? 'text-[hsl(var(--status-warning))]' : 'text-muted-foreground hover:text-foreground'}`}
              disabled={checkingVersions}
              onClick={onCheckVersions}
            >
              <RefreshCw className={`h-3 w-3 ${checkingVersions ? 'animate-spin' : ''}`} />
              {checkingVersions ? 'Söker...' : 'Sök uppdateringar'}
            </Button>
            {updatesAvailable && (
              <span className="absolute -top-0.5 -right-0.5 h-2.5 w-2.5 rounded-full bg-[hsl(var(--status-warning))] border-2 border-background" />
            )}
          </div>
        </div>

        <div className="flex items-center gap-2">
          <div className={`flex-1 flex items-center justify-between rounded px-2 py-1 text-[10px] font-mono ${dashboardVersion?.hasUpdate ? 'bg-[hsl(var(--status-warning)/0.08)] border border-[hsl(var(--status-warning)/0.25)]' : 'bg-secondary/30'}`}>
            <span className="text-muted-foreground">Version {dashboardVersion?.local || '—'}</span>
            {dashboardVersion?.hasUpdate ? (
              <span className="text-[hsl(var(--status-warning))]">Ny version</span>
            ) : (
              <span className="text-muted-foreground/50">✓</span>
            )}
          </div>
          <Button
            variant={dashboardVersion?.hasUpdate ? 'default' : 'secondary'}
            size="sm"
            className="font-mono text-[11px] gap-1 h-7 px-2"
            disabled={isUpdatingDashboard}
            onClick={onDashboardUpdate}
          >
            <RefreshCw className={`h-3 w-3 ${isUpdatingDashboard ? 'animate-spin' : ''}`} />
            {isUpdatingDashboard ? 'Uppdaterar...' : 'Uppdatera'}
          </Button>
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
      </div>
    </div>
  );
}

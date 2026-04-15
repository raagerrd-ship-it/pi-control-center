import { Cpu, Thermometer, HardDrive, Clock, MemoryStick, RefreshCw, CheckCircle2, AlertCircle, Loader2 } from 'lucide-react';
import { Progress } from '@/components/ui/progress';
import { Button } from '@/components/ui/button';
import type { SystemStatus, UpdateResult, VersionInfo } from '@/lib/api';
import type { ConnectionState } from '@/hooks/useSystemStatus';

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
  connection: ConnectionState;
  dashboardVersion?: VersionInfo;
  dashboardUpdate: UpdateResult | null;
  isUpdatingDashboard: boolean;
  checkingVersions: boolean;
  updatesAvailable: boolean;
  onCheckVersions: () => void;
  onDashboardUpdate: () => void;
}

export function SystemMonitor({
  status, error, loading, connection,
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

  const noData = error || !status;
  const busy = connection === 'busy';

  const cpuVal = noData ? '— %' : `${status.cpu}%`;
  const tempVal = noData ? '— °C' : `${status.temp}°C`;
  const ramVal = noData ? '— / — MB' : `${status.ramUsed}/${status.ramTotal} MB`;
  const diskVal = noData ? '— / — GB' : `${status.diskUsed}/${status.diskTotal} GB`;
  const uptimeVal = noData ? '—' : status.uptime;

  const ramPercent = noData ? 0 : Math.round((status.ramUsed / status.ramTotal) * 100);
  const diskPercent = noData ? 0 : Math.round((status.diskUsed / status.diskTotal) * 100);
  const dashboardPhase = dashboardUpdate?.progress || dashboardUpdate?.message || (busy ? 'Pi upptagen — väntar på svar...' : 'Startar uppdatering...');
  const dashboardVersionLabel = dashboardVersion?.local || (status?.commit ? status.commit.slice(0, 7) : '—');
  const dashboardUpdatedVersion = dashboardUpdate?.status === 'success' && dashboardVersion?.local
    ? dashboardVersion.local
    : null;

  return (
    <div className={`rounded-lg border p-4 flex flex-col gap-4 ${dashboardVersion?.hasUpdate ? 'border-[hsl(var(--status-warning)/0.3)] bg-[hsl(var(--status-warning)/0.05)]' : 'bg-card'}`}>
      {/* Connection banner */}
      {noData && (
        <div className={`flex items-center gap-2 rounded px-2.5 py-1.5 font-mono text-[11px] ${busy ? 'bg-[hsl(var(--status-warning)/0.1)] text-[hsl(var(--status-warning))]' : 'bg-destructive/10 text-destructive'}`}>
          {busy ? (
            <><Loader2 className="h-3 w-3 animate-spin" /> Pi upptagen — väntar på svar</>
          ) : (
            <><AlertCircle className="h-3 w-3" /> Ingen anslutning till Pi</>
          )}
        </div>
      )}
      {/* System gauges */}
      <div className="flex flex-col gap-3">
        {/* CPU: total + per-core */}
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center gap-2 text-muted-foreground">
            <Cpu className="h-3.5 w-3.5" />
            <span className="text-xs uppercase tracking-wider">CPU</span>
            <span className={`ml-auto font-mono text-sm font-semibold ${!noData && status.cpu > 85 ? 'text-destructive' : 'text-foreground'}`}>
              {cpuVal}
            </span>
          </div>
          <Progress value={noData ? 0 : status.cpu} className="h-1.5 bg-secondary" />
          {!noData && status.cpuCores && status.cpuCores.length > 0 && (
            <div className="grid grid-cols-4 gap-1.5 mt-1">
              {status.cpuCores.map((core, i) => (
                <div key={i} className="flex flex-col gap-0.5">
                  <div className="flex items-center justify-between">
                    <span className="font-mono text-[10px] text-muted-foreground">Core {i}</span>
                    <span className={`font-mono text-[10px] font-medium ${core > 85 ? 'text-destructive' : 'text-foreground'}`}>{core}%</span>
                  </div>
                  <Progress value={core} className="h-1 bg-secondary" />
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Other gauges */}
        <div className="grid grid-cols-2 gap-3">
          <Gauge icon={<Thermometer className="h-3.5 w-3.5" />} label="Temp" value={tempVal} percent={noData ? undefined : Math.min(status.temp, 85)} warning={!noData && status.temp > 70} />
          <Gauge icon={<MemoryStick className="h-3.5 w-3.5" />} label="RAM" value={ramVal} percent={noData ? undefined : ramPercent} warning={!noData && ramPercent > 85} />
          <Gauge icon={<HardDrive className="h-3.5 w-3.5" />} label="Disk" value={diskVal} percent={noData ? undefined : diskPercent} warning={!noData && diskPercent > 90} />
          <Gauge icon={<Clock className="h-3.5 w-3.5" />} label="Drifttid" value={uptimeVal} />
        </div>
      </div>

      {/* Separator */}
      <div className="border-t border-border" />

      {/* Dashboard row */}
      <div className="flex flex-col gap-2">
        <div className="flex items-center gap-2 flex-wrap">
          <div className={`h-2 w-2 rounded-full shrink-0 ${noData ? 'bg-muted-foreground/30' : 'bg-[hsl(var(--status-online))]'}`} />
          <span className="font-medium text-sm leading-none">Pi Control Center</span>
          <span className="font-mono text-[10px] text-muted-foreground inline-flex items-center rounded bg-secondary px-1.5 py-0.5">Core 0</span>
          <span className="font-mono text-[11px] text-muted-foreground">{noData ? '—' : `${status.dashboardCpu?.toFixed(1) ?? '0.0'}%`} · {noData ? '—' : `${status.dashboardRamMb ?? 7}MB`}</span>
        </div>

        <div className="flex items-center gap-2">
          <span className="font-mono text-[10px] text-muted-foreground">
            Version {dashboardVersionLabel}
          </span>
          {dashboardUpdate?.status === 'success' && (
            <span className="inline-flex items-center gap-1 rounded-md border border-[hsl(var(--status-online)/0.35)] bg-[hsl(var(--status-online)/0.12)] px-2 py-1 text-[11px] text-[hsl(var(--status-online))] font-mono">
              <CheckCircle2 className="h-3 w-3" /> Klar
            </span>
          )}
          {dashboardUpdate?.status === 'error' && (
            <span className="flex items-center gap-1 text-[11px] text-destructive font-mono" title={dashboardUpdate.message}>
              <AlertCircle className="h-3 w-3" /> Misslyckades
            </span>
          )}
          <div className="ml-auto">
            {dashboardVersion?.hasUpdate ? (
              <Button
                variant="default"
                size="sm"
                className="font-mono text-[11px] gap-1 h-7 px-2"
                disabled={isUpdatingDashboard}
                onClick={onDashboardUpdate}
              >
                <RefreshCw className={`h-3 w-3 ${isUpdatingDashboard ? 'animate-spin' : ''}`} />
                {isUpdatingDashboard ? 'Uppdaterar...' : 'Uppdatera'}
              </Button>
            ) : (
              <Button
                variant="ghost"
                size="sm"
                className={`font-mono text-[11px] gap-1 h-7 px-2 ${checkingVersions ? 'text-muted-foreground' : 'text-muted-foreground hover:text-foreground'}`}
                disabled={checkingVersions}
                onClick={onCheckVersions}
              >
                <RefreshCw className={`h-3 w-3 ${checkingVersions ? 'animate-spin' : ''}`} />
                {checkingVersions ? 'Söker...' : 'Sök uppdateringar'}
              </Button>
            )}
          </div>
        </div>

        {/* Update progress bar */}
        {isUpdatingDashboard && (
          <div className="flex flex-col gap-1.5 mt-1">
            <div className="h-1.5 w-full bg-secondary rounded-full overflow-hidden">
              <div className="h-full bg-primary rounded-full animate-pulse" style={{ width: '100%', opacity: 0.7 }} />
            </div>
            <div className="rounded-md border border-border bg-secondary/30 px-2.5 py-2">
              <div className="flex items-center justify-between gap-2">
                <span className="font-mono text-[10px] uppercase tracking-wider text-muted-foreground">Status</span>
                {dashboardUpdate?.elapsed && (
                  <span className="font-mono text-[10px] text-muted-foreground shrink-0">
                    {dashboardUpdate.elapsed}
                  </span>
                )}
              </div>
              <p className="mt-1 font-mono text-[11px] leading-relaxed text-foreground break-words">
                {dashboardPhase}
              </p>
            </div>
          </div>
        )}

        {dashboardUpdate?.status === 'success' && (
          <div className="mt-1 rounded-md border border-[hsl(var(--status-online)/0.35)] bg-[hsl(var(--status-online)/0.08)] px-2.5 py-2">
            <div className="flex items-start gap-2">
              <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-[hsl(var(--status-online))]" />
              <div className="min-w-0">
                <p className="font-mono text-[11px] text-[hsl(var(--status-online))]">Dashboard uppdaterad</p>
                <p className="mt-0.5 font-mono text-[10px] text-muted-foreground break-words">
                  Kör nu version {dashboardUpdatedVersion || dashboardVersionLabel}
                </p>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

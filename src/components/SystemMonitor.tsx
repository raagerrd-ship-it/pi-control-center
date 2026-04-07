import { Cpu, Thermometer, HardDrive, Clock, MemoryStick } from 'lucide-react';
import { Progress } from '@/components/ui/progress';
import type { SystemStatus } from '@/lib/api';

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
        <Progress
          value={percent}
          className="h-1.5 bg-secondary"
        />
      )}
    </div>
  );
}

interface SystemMonitorProps {
  status: SystemStatus | null;
  error: string | null;
  loading: boolean;
}

export function SystemMonitor({ status, error, loading }: SystemMonitorProps) {
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
    <div className="rounded-lg border bg-card p-4">
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-5">
        <Gauge
          icon={<Cpu className="h-3.5 w-3.5" />}
          label="CPU"
          value={`${status.cpu}%`}
          percent={status.cpu}
          warning={status.cpu > 85}
        />
        <Gauge
          icon={<Thermometer className="h-3.5 w-3.5" />}
          label="Temp"
          value={`${status.temp}°C`}
          percent={Math.min(status.temp, 85)}
          warning={status.temp > 70}
        />
        <Gauge
          icon={<MemoryStick className="h-3.5 w-3.5" />}
          label="RAM"
          value={`${status.ramUsed}/${status.ramTotal} MB`}
          percent={ramPercent}
          warning={ramPercent > 85}
        />
        <Gauge
          icon={<HardDrive className="h-3.5 w-3.5" />}
          label="Disk"
          value={`${status.diskUsed}/${status.diskTotal} GB`}
          percent={diskPercent}
          warning={diskPercent > 90}
        />
        <Gauge
          icon={<Clock className="h-3.5 w-3.5" />}
          label="Drifttid"
          value={status.uptime}
        />
      </div>
    </div>
  );
}
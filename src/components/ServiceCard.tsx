import { ExternalLink, RefreshCw, CheckCircle2, AlertCircle, Download, Loader2, Play, Square, RotateCcw, Cpu, FileText } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { LogViewer } from '@/components/LogViewer';
import type { UpdateResult, InstallResult, ServiceActionResult, VersionInfo } from '@/lib/api';

interface ServiceCardProps {
  name: string;
  appKey: string;
  port: number;
  piIp: string;
  online: boolean;
  installed: boolean;
  version: string;
  cpu: number;
  ramMb: number;
  cpuCore: number;
  deviceLabel?: string;
  versionInfo?: VersionInfo;
  updateStatus?: UpdateResult;
  installStatus?: InstallResult;
  actionStatus?: ServiceActionResult | { status: 'pending'; action: string };
  onUpdate: (app: string) => void;
  onInstall: (app: string) => void;
  onServiceAction: (app: string, action: 'start' | 'stop' | 'restart') => void;
}

export function ServiceCard({
  name,
  appKey,
  port,
  piIp,
  online,
  installed,
  version,
  cpu,
  ramMb,
  cpuCore,
  versionInfo,
  updateStatus,
  installStatus,
  actionStatus,
  onUpdate,
  onInstall,
  onServiceAction,
}: ServiceCardProps) {
  const isUpdating = updateStatus?.status === 'updating';
  const isInstalling = installStatus?.status === 'installing';
  const installSuccess = installStatus?.status === 'success';
  const installError = installStatus?.status === 'error';
  const isPending = actionStatus?.status === 'pending';
  const hasUpdate = versionInfo?.hasUpdate ?? false;

  const statusColor = !installed
    ? 'bg-muted-foreground'
    : online
      ? 'bg-[hsl(var(--status-online))]'
      : 'bg-[hsl(var(--status-offline))]';

  return (
    <div className={`rounded-lg border bg-card p-3.5 flex flex-col gap-2.5 transition-colors ${online ? 'border-border' : 'border-border/50'}`}>
      {/* Header: status dot + name + actions */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className={`h-2 w-2 rounded-full ${statusColor}`} />
          <h3 className="font-medium text-sm leading-none">{name}</h3>
          <span className="font-mono text-[11px] text-muted-foreground">:{port}</span>
        </div>
        {installed && online && (
          <a
            href={`http://${piIp}:${port}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-muted-foreground hover:text-foreground transition-colors"
            title={`Öppna ${name}`}
          >
            <ExternalLink className="h-3.5 w-3.5" />
          </a>
        )}
      </div>

      {/* Resource row — compact single line */}
      {installed && (
        <div className="flex items-center gap-2 font-mono text-[11px] text-muted-foreground">
          {cpuCore >= 0 && (
            <span className="inline-flex items-center gap-1 rounded bg-secondary px-1.5 py-0.5">
              <Cpu className={`h-3 w-3 ${online ? 'text-[hsl(var(--status-online))]' : 'text-muted-foreground'}`} />
              <span className="text-foreground text-[10px]">{cpuCore}</span>
            </span>
          )}
          {online ? (
            <>
              <span className={cpu > 50 ? 'text-[hsl(var(--status-warning))]' : ''}>
                {cpu.toFixed(1)}%
              </span>
              <span className="text-border">·</span>
              <span>{ramMb}MB</span>
            </>
          ) : (
            <span className="text-muted-foreground/60">Offline</span>
          )}
        </div>
      )}

      {!installed && (
        <span className="font-mono text-[11px] text-muted-foreground/60">Ej installerad</span>
      )}

      {/* Install progress */}
      {isInstalling && (
        <div className="flex flex-col gap-1">
          <div className="flex items-center gap-1.5 text-xs text-[hsl(var(--status-warning))]">
            <Loader2 className="h-3 w-3 animate-spin" />
            <span className="font-mono text-[11px]">{installStatus?.progress || 'Installerar...'}</span>
          </div>
          <Progress value={undefined} className="h-1 bg-secondary animate-pulse" />
        </div>
      )}

      {installSuccess && (
        <span className="flex items-center gap-1 text-[11px] text-[hsl(var(--status-online))] font-mono">
          <CheckCircle2 className="h-3 w-3" /> Installerad
        </span>
      )}

      {installError && (
        <span className="flex items-center gap-1 text-[11px] text-destructive font-mono" title={installStatus?.message}>
          <AlertCircle className="h-3 w-3" /> Installation misslyckades
        </span>
      )}

      {/* Service action feedback */}
      {actionStatus && 'action' in actionStatus && (
        <div className="font-mono text-[11px]">
          {actionStatus.status === 'pending' && (
            <span className="flex items-center gap-1 text-[hsl(var(--status-warning))]">
              <Loader2 className="h-3 w-3 animate-spin" />
              {actionStatus.action === 'start' ? 'Startar...' : actionStatus.action === 'stop' ? 'Stoppar...' : 'Startar om...'}
            </span>
          )}
          {actionStatus.status === 'success' && (
            <span className="flex items-center gap-1 text-[hsl(var(--status-online))]">
              <CheckCircle2 className="h-3 w-3" /> {actionStatus.action === 'start' ? 'Startad' : actionStatus.action === 'stop' ? 'Stoppad' : 'Omstartad'}
            </span>
          )}
          {actionStatus.status === 'error' && (
            <span className="flex items-center gap-1 text-destructive" title={'message' in actionStatus ? actionStatus.message : ''}>
              <AlertCircle className="h-3 w-3" /> Misslyckades
            </span>
          )}
        </div>
      )}

      {/* Actions */}
      <div className="flex flex-col gap-1.5 mt-auto">
        {!installed && !isInstalling && !installSuccess ? (
          <Button
            variant="default"
            size="sm"
            className="font-mono text-xs gap-1.5"
            disabled={isInstalling}
            onClick={() => onInstall(appKey)}
          >
            <Download className="h-3 w-3" />
            Installera
          </Button>
        ) : (
          <>
            {/* Controls + version in one compact row */}
            <div className="flex items-center gap-1">
              {!online ? (
                <Button
                  variant="secondary"
                  size="sm"
                  className="font-mono text-[11px] gap-1 h-7 px-2.5 flex-1"
                  disabled={isPending || !installed}
                  onClick={() => onServiceAction(appKey, 'start')}
                >
                  <Play className="h-3 w-3" /> Starta
                </Button>
              ) : (
                <Button
                  variant="secondary"
                  size="sm"
                  className="font-mono text-[11px] gap-1 h-7 px-2.5 flex-1"
                  disabled={isPending}
                  onClick={() => onServiceAction(appKey, 'stop')}
                >
                  <Square className="h-3 w-3" /> Stoppa
                </Button>
              )}
              <Button
                variant="secondary"
                size="sm"
                className="font-mono text-[11px] h-7 w-7 p-0"
                disabled={isPending || !online}
                onClick={() => onServiceAction(appKey, 'restart')}
                title="Starta om"
              >
                <RotateCcw className="h-3 w-3" />
              </Button>
            </div>

            {/* Version + update — minimal bar */}
            <div className={`flex items-center justify-between rounded px-2 py-1 text-[10px] font-mono ${hasUpdate ? 'bg-[hsl(var(--status-warning)/0.08)] border border-[hsl(var(--status-warning)/0.25)]' : 'bg-secondary/30'}`}>
              <span className="text-muted-foreground">{version || '—'}</span>
              {hasUpdate ? (
                <button
                  className="text-[hsl(var(--status-warning))] hover:text-foreground transition-colors inline-flex items-center gap-1 disabled:opacity-50"
                  disabled={isUpdating || !online}
                  onClick={() => onUpdate(appKey)}
                >
                  <RefreshCw className={`h-2.5 w-2.5 ${isUpdating ? 'animate-spin' : ''}`} />
                  {isUpdating ? 'Uppdaterar' : 'Uppdatera'}
                </button>
              ) : (
                <span className="text-muted-foreground/50">✓</span>
              )}
            </div>

            {/* Update feedback */}
            {updateStatus?.status === 'success' && (
              <span className="flex items-center gap-1 text-[11px] text-[hsl(var(--status-online))] font-mono">
                <CheckCircle2 className="h-3 w-3" /> Klar
              </span>
            )}
            {updateStatus?.status === 'error' && (
              <span className="flex items-center gap-1 text-[11px] text-destructive font-mono" title={updateStatus.message}>
                <AlertCircle className="h-3 w-3" /> Misslyckades
              </span>
            )}

            {/* Logs */}
            <LogViewer appKey={appKey} appName={name} />
          </>
        )}
      </div>
    </div>
  );
}

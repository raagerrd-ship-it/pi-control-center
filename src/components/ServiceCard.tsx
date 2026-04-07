import { ExternalLink, RefreshCw, CheckCircle2, XCircle, AlertCircle, Download, Loader2, Play, Square, RotateCcw } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { LogViewer } from '@/components/LogViewer';
import type { UpdateResult, InstallResult, ServiceActionResult } from '@/lib/api';

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

  const statusColor = !installed
    ? 'bg-muted-foreground'
    : online
      ? 'bg-[hsl(var(--status-online))]'
      : 'bg-[hsl(var(--status-offline))]';

  const statusLabel = !installed
    ? 'Ej installerad'
    : online
      ? 'Online'
      : 'Offline';

  return (
    <div className="rounded-lg border bg-card p-4 flex flex-col gap-3">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2.5">
          <div className={`h-2.5 w-2.5 rounded-full ${statusColor}`} />
          <h3 className="font-medium text-sm">{name}</h3>
        </div>
        {installed && (
          <a
            href={`http://${piIp}:${port}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-muted-foreground hover:text-foreground transition-colors"
          >
            <ExternalLink className="h-4 w-4" />
          </a>
        )}
      </div>

      {/* Meta */}
      <div className="flex items-center gap-3 font-mono text-xs text-muted-foreground">
        <span>:{port}</span>
        <span className="text-border">|</span>
        <span>{installed ? (version || statusLabel) : statusLabel}</span>
      </div>

      {/* Resource usage */}
      {installed && online && (
        <div className="flex items-center gap-2.5 font-mono text-[11px]">
          <span className="text-muted-foreground/60">Core {cpuCore}</span>
          <span className="text-border">·</span>
          <span className={cpu > 50 ? 'text-[hsl(var(--status-warning))]' : 'text-muted-foreground'}>
            {cpu.toFixed(1)}%
          </span>
          <span className="text-border">·</span>
          <span className="text-muted-foreground">
            {ramMb}MB
          </span>
        </div>
      )}

      {/* Install progress */}
      {isInstalling && (
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center gap-1.5 text-xs text-[hsl(var(--status-warning))]">
            <Loader2 className="h-3 w-3 animate-spin" />
            <span className="font-mono">{installStatus?.progress || 'Installerar...'}</span>
          </div>
          <Progress value={undefined} className="h-1 bg-secondary animate-pulse" />
        </div>
      )}

      {installSuccess && (
        <span className="flex items-center gap-1 text-xs text-[hsl(var(--status-online))] font-mono">
          <CheckCircle2 className="h-3 w-3" /> Installerad!
        </span>
      )}

      {installError && (
        <span className="flex items-center gap-1 text-xs text-destructive font-mono" title={installStatus?.message}>
          <AlertCircle className="h-3 w-3" /> Installation misslyckades
        </span>
      )}

      {/* Service action feedback */}
      {actionStatus && 'action' in actionStatus && (
        <div className="font-mono text-xs">
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
      <div className="flex flex-col gap-2 mt-auto">
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
            {/* Service controls */}
            <div className="flex items-center gap-1.5">
              {!online ? (
                <Button
                  variant="secondary"
                  size="sm"
                  className="font-mono text-xs gap-1 flex-1"
                  disabled={isPending || !installed}
                  onClick={() => onServiceAction(appKey, 'start')}
                >
                  <Play className="h-3 w-3" /> Starta
                </Button>
              ) : (
                <Button
                  variant="secondary"
                  size="sm"
                  className="font-mono text-xs gap-1 flex-1"
                  disabled={isPending}
                  onClick={() => onServiceAction(appKey, 'stop')}
                >
                  <Square className="h-3 w-3" /> Stoppa
                </Button>
              )}
              <Button
                variant="secondary"
                size="sm"
                className="font-mono text-xs gap-1 flex-1"
                disabled={isPending || !online}
                onClick={() => onServiceAction(appKey, 'restart')}
              >
                <RotateCcw className="h-3 w-3" /> Omstart
              </Button>
            </div>

            {/* Update button */}
            <div className="flex items-center gap-2">
              <Button
                variant="ghost"
                size="sm"
                className="font-mono text-xs gap-1.5 text-muted-foreground hover:text-foreground"
                disabled={isUpdating || !online}
                onClick={() => onUpdate(appKey)}
              >
                <RefreshCw className={`h-3 w-3 ${isUpdating ? 'animate-spin' : ''}`} />
                {isUpdating ? 'Uppdaterar...' : 'Uppdatera'}
              </Button>

              {updateStatus?.status === 'success' && (
                <span className="flex items-center gap-1 text-xs text-[hsl(var(--status-online))]">
                  <CheckCircle2 className="h-3 w-3" /> Klar
                </span>
              )}
              {updateStatus?.status === 'error' && (
                <span className="flex items-center gap-1 text-xs text-destructive" title={updateStatus.message}>
                  <AlertCircle className="h-3 w-3" /> Fel
                </span>
              )}
            </div>

            {/* Log viewer */}
            <LogViewer appKey={appKey} appName={name} />
          </>
        )}
      </div>
    </div>
  );
}

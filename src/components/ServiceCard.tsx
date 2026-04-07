import { ExternalLink, RefreshCw, CheckCircle2, XCircle, AlertCircle, Download, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import type { UpdateResult, InstallResult } from '@/lib/api';

interface ServiceCardProps {
  name: string;
  appKey: string;
  port: number;
  piIp: string;
  online: boolean;
  installed: boolean;
  version: string;
  updateStatus?: UpdateResult;
  installStatus?: InstallResult;
  onUpdate: (app: string) => void;
  onInstall: (app: string) => void;
}

export function ServiceCard({
  name,
  appKey,
  port,
  piIp,
  online,
  installed,
  version,
  updateStatus,
  installStatus,
  onUpdate,
  onInstall,
}: ServiceCardProps) {
  const isUpdating = updateStatus?.status === 'updating';
  const isInstalling = installStatus?.status === 'installing';
  const installSuccess = installStatus?.status === 'success';
  const installError = installStatus?.status === 'error';

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

      <div className="flex items-center gap-3 font-mono text-xs text-muted-foreground">
        <span>:{port}</span>
        <span className="text-border">|</span>
        <span>{installed ? (version || statusLabel) : statusLabel}</span>
      </div>

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

      <div className="flex items-center gap-2 mt-auto">
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
            <Button
              variant="secondary"
              size="sm"
              className="font-mono text-xs gap-1.5"
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
            {!online && installed && (
              <span className="flex items-center gap-1 text-xs text-muted-foreground">
                <XCircle className="h-3 w-3" /> Offline
              </span>
            )}
          </>
        )}
      </div>
    </div>
  );
}

import { ExternalLink, RefreshCw, CheckCircle2, XCircle, AlertCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import type { UpdateResult } from '@/lib/api';

interface ServiceCardProps {
  name: string;
  appKey: string;
  port: number;
  piIp: string;
  online: boolean;
  version: string;
  updateStatus?: UpdateResult;
  onUpdate: (app: string) => void;
}

export function ServiceCard({
  name,
  appKey,
  port,
  piIp,
  online,
  version,
  updateStatus,
  onUpdate,
}: ServiceCardProps) {
  const isUpdating = updateStatus?.status === 'updating';
  const statusColor = online
    ? 'bg-[hsl(var(--status-online))]'
    : 'bg-[hsl(var(--status-offline))]';

  return (
    <div className="rounded-lg border bg-card p-4 flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2.5">
          <div className={`h-2.5 w-2.5 rounded-full ${statusColor}`} />
          <h3 className="font-medium text-sm">{name}</h3>
        </div>
        <a
          href={`http://${piIp}:${port}`}
          target="_blank"
          rel="noopener noreferrer"
          className="text-muted-foreground hover:text-foreground transition-colors"
        >
          <ExternalLink className="h-4 w-4" />
        </a>
      </div>

      <div className="flex items-center gap-3 font-mono text-xs text-muted-foreground">
        <span>:{port}</span>
        {version && (
          <>
            <span className="text-border">|</span>
            <span>{version}</span>
          </>
        )}
      </div>

      <div className="flex items-center gap-2 mt-auto">
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
        {!online && (
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            <XCircle className="h-3 w-3" /> Offline
          </span>
        )}
      </div>
    </div>
  );
}

import { useState, memo } from 'react';
import { ExternalLink, RefreshCw, CheckCircle2, AlertCircle, Loader2, Play, Square, RotateCcw, Trash2, Plus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { InstallDialog } from '@/components/InstallDialog';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import type { UpdateResult, InstallResult, ServiceActionResult, VersionInfo, SystemStatus, ServiceDefinition } from '@/lib/api';

interface CoreCardProps {
  coreIndex: number;
  /** Service installed on this core, if any */
  service?: {
    definition: ServiceDefinition;
    online: boolean;
    installed: boolean;
    version: string;
    cpu: number;
    ramMb: number;
    port?: number;
    versionInfo?: VersionInfo;
    updateStatus?: UpdateResult;
    installStatus?: InstallResult;
    actionStatus?: ServiceActionResult | { status: 'pending'; action: string };
  };
  /** Services available to install (not yet installed) */
  availableServices: ServiceDefinition[];
  usedPorts: number[];
  status: SystemStatus | null;
  onUpdate: (app: string) => void;
  onInstall: (app: string, port: number, core: number) => void;
  onUninstall: (app: string) => void;
  onServiceAction: (app: string, action: 'start' | 'stop' | 'restart') => void;
}

export const CoreCard = memo(function CoreCard({
  coreIndex,
  service,
  availableServices,
  usedPorts,
  status,
  onUpdate,
  onInstall,
  onUninstall,
  onServiceAction,
}: CoreCardProps) {
  const [selectedService, setSelectedService] = useState<string>('');

  // Empty core — show add service UI
  if (!service || !service.installed) {
    const installing = service?.installStatus?.status === 'installing';
    const installSuccess = service?.installStatus?.status === 'success';
    const installError = service?.installStatus?.status === 'error';

    // If we're in the middle of installing, show progress
    if (installing || installSuccess || installError) {
      const name = service?.definition.name ?? 'Tjänst';
      return (
        <div className="rounded-lg border border-border/50 bg-card p-3.5 flex flex-col gap-2.5">
          <div className="flex items-center justify-between">
            <span className="font-mono text-[11px] text-muted-foreground uppercase tracking-wider">Core {coreIndex}</span>
          </div>
          <h3 className="font-medium text-sm">{name}</h3>
          {installing && (
            <div className="flex flex-col gap-1">
              <div className="flex items-center gap-1.5 text-[hsl(var(--status-warning))]">
                <Loader2 className="h-3 w-3 animate-spin" />
                <span className="font-mono text-[11px]">{service?.installStatus?.progress || 'Installerar...'}</span>
              </div>
              {service?.installStatus?.elapsed && (
                <span className="font-mono text-[10px] text-muted-foreground pl-4.5">⏱ {service.installStatus.elapsed}</span>
              )}
              <Progress value={undefined} className="h-1 bg-secondary animate-pulse" />
            </div>
          )}
          {installSuccess && (
            <span className="flex items-center gap-1 text-[11px] text-[hsl(var(--status-online))] font-mono">
              <CheckCircle2 className="h-3 w-3" /> Installerad
            </span>
          )}
          {installError && (
            <span className="flex items-center gap-1 text-[11px] text-destructive font-mono" title={service?.installStatus?.message}>
              <AlertCircle className="h-3 w-3" /> Installation misslyckades
            </span>
          )}
        </div>
      );
    }

    return (
      <div className="rounded-lg border border-dashed border-border/50 bg-card/50 p-3.5 flex flex-col gap-3">
        <div className="flex items-center justify-between">
          <span className="font-mono text-[11px] text-muted-foreground uppercase tracking-wider">Core {coreIndex}</span>
          <span className="font-mono text-[10px] text-muted-foreground/50">Ledig</span>
        </div>

        {availableServices.length > 0 ? (
          <div className="flex flex-col gap-2">
            <Select value={selectedService} onValueChange={setSelectedService}>
              <SelectTrigger className="font-mono text-xs h-8">
                <SelectValue placeholder="Välj tjänst..." />
              </SelectTrigger>
              <SelectContent>
                {availableServices.map(svc => (
                  <SelectItem key={svc.key} value={svc.key} className="font-mono text-xs">
                    {svc.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>

            {selectedService && (
              <InstallDialog
                appKey={selectedService}
                appName={availableServices.find(s => s.key === selectedService)?.name ?? selectedService}
                core={coreIndex}
                usedPorts={usedPorts}
                status={status}
                onInstall={onInstall}
              />
            )}
          </div>
        ) : (
          <p className="font-mono text-[11px] text-muted-foreground/50 text-center py-2">
            Alla tjänster installerade
          </p>
        )}
      </div>
    );
  }

  // Occupied core — show service info
  const { definition: def, online, version, cpu, ramMb, port, versionInfo, updateStatus, actionStatus } = service;
  const isUpdating = updateStatus?.status === 'updating';
  const isPending = actionStatus?.status === 'pending';
  const hasUpdate = versionInfo?.hasUpdate ?? false;
  const piIp = window.location.hostname;

  const statusColor = online
    ? 'bg-[hsl(var(--status-online))]'
    : 'bg-[hsl(var(--status-offline))]';

  return (
    <div className={`rounded-lg border bg-card p-3.5 flex flex-col gap-2.5 transition-colors ${online ? 'border-border' : 'border-border/50'}`}>
      {/* Header */}
      <div className="flex items-center justify-between">
        <span className="font-mono text-[11px] text-muted-foreground uppercase tracking-wider">Core {coreIndex}</span>
        <div className="flex items-center gap-1.5">
          <div className={`h-2 w-2 rounded-full ${statusColor}`} />
          {port ? <span className="font-mono text-[11px] text-muted-foreground">:{port}</span> : null}
        </div>
      </div>

      <h3 className="font-medium text-sm leading-none">{def.name}</h3>

      {/* Resource row */}
      <div className="flex items-center gap-2 font-mono text-[11px] text-muted-foreground">
        {online ? (
          <>
            <span className={cpu > 50 ? 'text-[hsl(var(--status-warning))]' : ''}>
              {cpu.toFixed(1)}%
            </span>
            <span className="text-border">·</span>
            <span>{ramMb}MB</span>
          </>
        ) : (
          <span className="inline-flex items-center gap-1 rounded bg-[hsl(var(--status-offline)/0.15)] px-1.5 py-0.5 text-[hsl(var(--status-offline))] text-[10px] font-medium">
            Offline
          </span>
        )}
      </div>

      {/* Action feedback */}
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
            <span className="flex items-center gap-1 text-destructive">
              <AlertCircle className="h-3 w-3" />
              {'message' in actionStatus && actionStatus.message ? actionStatus.message : 'Misslyckades'}
            </span>
          )}
        </div>
      )}

      {/* Version bar */}
      <div className={`flex items-center justify-between rounded px-2 py-1 text-[10px] font-mono ${hasUpdate ? 'bg-[hsl(var(--status-warning)/0.08)] border border-[hsl(var(--status-warning)/0.25)]' : 'bg-secondary/30'}`}>
        <span className="text-muted-foreground">Version {version || '—'}</span>
        {hasUpdate ? (
          <span className="text-[hsl(var(--status-warning))]">Ny version</span>
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
        <div className="flex flex-col gap-0.5">
          <span className="flex items-center gap-1 text-[11px] text-destructive font-mono">
            <AlertCircle className="h-3 w-3" /> Misslyckades
          </span>
          {updateStatus.message && (
            <span className="text-[10px] text-destructive/70 font-mono pl-4 break-all">
              {updateStatus.message}
            </span>
          )}
        </div>
      )}

      {/* Actions */}
      <div className="flex items-center gap-1 mt-auto flex-wrap">
        {!online ? (
          <Button variant="secondary" size="sm" className="font-mono text-[11px] gap-1 h-7 px-2 flex-1" disabled={isPending} onClick={() => onServiceAction(def.key, 'start')}>
            <Play className="h-3 w-3" /> Starta
          </Button>
        ) : (
          <Button variant="secondary" size="sm" className="font-mono text-[11px] gap-1 h-7 px-2 flex-1" disabled={isPending} onClick={() => onServiceAction(def.key, 'stop')}>
            <Square className="h-3 w-3" /> Stoppa
          </Button>
        )}
        <Button variant="secondary" size="sm" className="font-mono text-[11px] gap-1 h-7 px-2" disabled={isPending || !online} onClick={() => onServiceAction(def.key, 'restart')}>
          <RotateCcw className="h-3 w-3" /> Omstart
        </Button>
        {hasUpdate && (
          <Button variant="default" size="sm" className="font-mono text-[11px] gap-1 h-7 px-2" disabled={isUpdating} onClick={() => onUpdate(def.key)}>
            <RefreshCw className={`h-3 w-3 ${isUpdating ? 'animate-spin' : ''}`} />
            {isUpdating ? '...' : 'Uppdatera'}
          </Button>
        )}
        {online && port && (
          <a href={`http://${piIp}:${port}`} target="_blank" rel="noopener noreferrer" className="inline-flex items-center justify-center gap-1 h-7 px-2 rounded-md bg-secondary font-mono text-[11px] text-muted-foreground hover:text-foreground transition-colors">
            <ExternalLink className="h-3 w-3" /> Öppna
          </a>
        )}
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="ghost" size="sm" className="font-mono text-[11px] gap-1 h-7 px-2 text-destructive hover:text-destructive">
              <Trash2 className="h-3 w-3" />
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle className="font-mono text-sm">Avinstallera {def.name}?</AlertDialogTitle>
              <AlertDialogDescription className="text-xs">Tjänsten stoppas och tas bort. Detta kan inte ångras.</AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel className="font-mono text-xs">Avbryt</AlertDialogCancel>
              <AlertDialogAction className="font-mono text-xs bg-destructive text-destructive-foreground hover:bg-destructive/90" onClick={() => onUninstall(def.key)}>
                Avinstallera
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </div>
    </div>
  );
});

import { AlertTriangle, Trash2, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
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
import type { ServiceStatus, UninstallResult } from '@/lib/api';

interface OrphanedServiceCardProps {
  serviceKey: string;
  displayName: string;
  status: ServiceStatus;
  uninstallStatus?: UninstallResult | { status: 'pending' };
  onUninstall: (app: string) => void;
}

export function OrphanedServiceCard({
  serviceKey,
  displayName,
  status,
  uninstallStatus,
  onUninstall,
}: OrphanedServiceCardProps) {
  const isPending = uninstallStatus?.status === 'pending';

  // Diagnose what's broken
  const reasons: string[] = [];
  if (status.cpuCore < 1) reasons.push('saknar core-tilldelning');
  const engineMissing = status.components?.engine && !status.components.engine.service;
  const uiMissing = status.components?.ui && !status.components.ui.service;
  if (engineMissing || uiMissing) reasons.push('systemd-unit saknas');
  if (!status.port || status.port === 0) reasons.push('saknar port');
  if (reasons.length === 0) reasons.push('felaktig konfiguration');

  return (
    <div className="rounded-lg border border-[hsl(var(--status-warning)/0.4)] bg-[hsl(var(--status-warning)/0.05)] p-3.5 flex flex-col gap-2.5">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-1.5">
          <AlertTriangle className="h-3.5 w-3.5 text-[hsl(var(--status-warning))]" />
          <span className="font-mono text-[11px] text-[hsl(var(--status-warning))] uppercase tracking-wider">
            Föräldralös
          </span>
        </div>
        <span className="font-mono text-[10px] text-muted-foreground/60">
          core {status.cpuCore < 1 ? '—' : status.cpuCore}
        </span>
      </div>

      <h3 className="font-medium text-sm leading-none">{displayName || serviceKey}</h3>

      <div className="font-mono text-[10px] text-muted-foreground space-y-0.5">
        <div>Installerad men inte korrekt registrerad:</div>
        <ul className="list-disc list-inside text-[hsl(var(--status-warning))] pl-1">
          {reasons.map(r => <li key={r}>{r}</li>)}
        </ul>
      </div>

      {(status.components?.engine || status.components?.ui) && (
        <div className="font-mono text-[10px] text-muted-foreground/70 border-t border-border/30 pt-1.5 space-y-0.5">
          {status.components.engine && (
            <div>motor: {status.components.engine.service || '—'} {status.components.engine.port ? `:${status.components.engine.port}` : ''}</div>
          )}
          {status.components.ui && (
            <div>ui: {status.components.ui.service || '—'} {status.components.ui.port ? `:${status.components.ui.port}` : ''}</div>
          )}
        </div>
      )}

      <AlertDialog>
        <AlertDialogTrigger asChild>
          <Button
            variant="outline"
            size="sm"
            className="font-mono text-xs gap-1.5 w-full border-destructive/40 text-destructive hover:bg-destructive/10 hover:text-destructive"
            disabled={isPending}
          >
            {isPending ? <Loader2 className="h-3 w-3 animate-spin" /> : <Trash2 className="h-3 w-3" />}
            Städa upp / avinstallera
          </Button>
        </AlertDialogTrigger>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Avinstallera {displayName || serviceKey}?</AlertDialogTitle>
            <AlertDialogDescription>
              Tjänsten är felaktigt installerad. Avinstallation rensar bort rester så du kan installera om från början.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="font-mono text-xs">Avbryt</AlertDialogCancel>
            <AlertDialogAction
              className="font-mono text-xs bg-destructive hover:bg-destructive/90"
              onClick={() => onUninstall(serviceKey)}
            >
              Avinstallera
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

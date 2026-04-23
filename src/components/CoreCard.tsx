import { useState, memo } from 'react';
import { ExternalLink, RefreshCw, CheckCircle2, AlertCircle, Loader2, Play, Square, RotateCcw, Trash2, Server, Monitor, Download, MemoryStick, ShieldCheck, KeyRound, FolderLock, Database, Terminal } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
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
import type { UpdateResult, InstallResult, ServiceActionResult, VersionInfo, ServiceDefinition, ComponentStatus, HealthStatus, WatchdogStatus } from '@/lib/api';
import { hasComponents, setMemoryLimit } from '@/lib/api';

interface CoreCardProps {
  coreIndex: number;
  service?: {
    definition: ServiceDefinition;
    online: boolean;
    installed: boolean;
    version: string;
    cpu: number;
    ramMb: number;
    memoryMaxMb?: number;
    memoryLevel?: string;
    memoryProfile?: ServiceDefinition['memoryProfile'] | null;
    permissions?: string[];
    configDir?: string;
    dataDir?: string;
    logDir?: string;
    port?: number;
    versionInfo?: VersionInfo;
    updateStatus?: UpdateResult;
    installStatus?: InstallResult;
    actionStatus?: ServiceActionResult | { status: 'pending'; action: string };
    components?: {
      engine?: ComponentStatus;
      ui?: ComponentStatus;
    };
    health?: HealthStatus;
    watchdog?: WatchdogStatus;
  };
  availableServices: ServiceDefinition[];
  allInstalls: Record<string, InstallResult>;
  memLimitMb: number | null;
  otherAllocatedMb: number;
  ramBudgetMb: number;
  onMemLimitChange: (app: string, mb: number) => void;
  onUpdate: (app: string) => void;
  onCheckVersion: (app: string) => Promise<void>;
  onInstall: (app: string, port: number, core: number) => void;
  onUninstall: (app: string) => void;
  onServiceAction: (app: string, action: 'start' | 'stop' | 'restart', component?: 'engine' | 'ui') => void;
}

const watchdogText: Record<string, string> = {
  ok: 'Skydd: OK',
  warning: 'Varning',
  restarting: 'Restartad av watchdog',
  protected: 'Skyddsstoppad',
  disabled: 'Skydd: av',
};

const watchdogReason: Record<string, string> = {
  high_cpu: 'CPU-loop',
  high_memory: 'hög RAM',
  health_timeout: 'svarar inte',
  restart_loop: 'restart-loop',
};

function WatchdogLine({ watchdog }: { watchdog?: WatchdogStatus }) {
  if (!watchdog || watchdog.status === 'ok') return null;
  const isProtected = watchdog.status === 'protected';
  const tone = isProtected ? 'text-destructive' : 'text-[hsl(var(--status-warning))]';
  const reason = watchdog.reason ? watchdogReason[watchdog.reason] ?? watchdog.reason : '';

  return (
    <div className={`flex items-center gap-1.5 font-mono text-[10px] ${tone}`} title={watchdog.lastAction || undefined}>
      <ShieldCheck className="h-3 w-3 shrink-0" />
      <span className="truncate">
        {watchdogText[watchdog.status] ?? 'Skydd'}{reason ? `: ${reason}` : ''}
      </span>
      {(watchdog.restartCount ?? 0) > 0 && <span className="text-muted-foreground/50 shrink-0">×{watchdog.restartCount}</span>}
    </div>
  );
}

function ComponentRow({
  label,
  icon: Icon,
  comp,
  alwaysOn,
  isPending,
  onAction,
}: {
  label: string;
  icon: React.ElementType;
  comp?: ComponentStatus;
  alwaysOn?: boolean;
  isPending: boolean;
  onAction: (action: 'start' | 'stop' | 'restart') => void;
}) {
  const online = comp?.online ?? false;

  return (
    <div className="flex flex-col py-1">
      <div className="flex items-center gap-2">
        <div className={`h-1.5 w-1.5 rounded-full shrink-0 ${online ? 'bg-[hsl(var(--status-online))]' : 'bg-[hsl(var(--status-offline))]'}`} />
        <Icon className="h-3 w-3 text-muted-foreground shrink-0" />
        <span className="font-mono text-[11px] flex-1 truncate">{label}</span>
        {comp?.port && (
          <span className="font-mono text-[10px] text-muted-foreground/50 shrink-0">:{comp.port}</span>
        )}
        {comp && online && (
          <span className="font-mono text-[10px] text-muted-foreground shrink-0">
            {comp.cpu.toFixed(1)}% · {comp.ramMb}MB
          </span>
        )}
        {comp?.cpuCore != null && (
          <span className="font-mono text-[9px] text-muted-foreground/40 bg-secondary/50 rounded px-1 py-0.5 shrink-0">
            C{comp.cpuCore}
          </span>
        )}
      </div>
      <div className="flex items-center justify-end gap-0.5 pl-5 -mt-0.5">
        {!online ? (
          <Button variant="ghost" size="sm" className="h-5 w-5 p-0" disabled={isPending} onClick={() => onAction('start')} title="Starta">
            <Play className="h-2.5 w-2.5" />
          </Button>
        ) : (
          <>
            {!alwaysOn && (
              <Button variant="ghost" size="sm" className="h-5 w-5 p-0" disabled={isPending} onClick={() => onAction('stop')} title="Stoppa">
                <Square className="h-2.5 w-2.5" />
              </Button>
            )}
            <Button variant="ghost" size="sm" className="h-5 w-5 p-0" disabled={isPending} onClick={() => onAction('restart')} title="Omstart">
              <RotateCcw className="h-2.5 w-2.5" />
            </Button>
          </>
        )}
      </div>
      <div className="pl-5">
        <WatchdogLine watchdog={comp?.watchdog} />
      </div>
    </div>
  );
}

export const CoreCard = memo(function CoreCard({
  coreIndex,
  service,
  availableServices,
  allInstalls,
  memLimitMb,
  otherAllocatedMb,
  ramBudgetMb,
  onMemLimitChange,
  onUpdate,
  onCheckVersion,
  onInstall,
  onUninstall,
  onServiceAction,
}: CoreCardProps) {
  const [selectedService, setSelectedService] = useState<string>('');
  const [installingService, setInstallingService] = useState<string>('');
  const [checkingVersion, setCheckingVersion] = useState(false);
  const [memLimitSaving, setMemLimitSaving] = useState(false);

  const uiPort = 3000 + coreIndex;
  const enginePort = 3050 + coreIndex;

  const handleInstall = (app: string) => {
    setInstallingService(app);
    onInstall(app, uiPort, coreIndex);
  };

  const MIN_MEMORY_MB = 80;
  const maxForThis = Math.max(MIN_MEMORY_MB, ramBudgetMb - otherAllocatedMb);

  // Sync local slider value with prop
  const profile = service?.definition.memoryProfile || service?.memoryProfile;
  const rawMemoryLevel = service?.memoryLevel || (profile && memLimitMb ? Object.entries(profile.levels).find(([, mb]) => mb === memLimitMb)?.[0] : undefined);
  const memoryLevel = rawMemoryLevel && ['low', 'balanced', 'high'].includes(rawMemoryLevel) ? rawMemoryLevel : (profile?.defaultLevel || 'balanced');
  const memoryMaxMb = Math.max(MIN_MEMORY_MB, service?.memoryMaxMb ?? memLimitMb ?? MIN_MEMORY_MB);

  const handleMemoryLevelChange = async (level: string) => {
    if (!service?.definition?.key || !profile?.levels[level]) return;
    const mb = Math.min(Math.max(profile.levels[level], MIN_MEMORY_MB), maxForThis);
    setMemLimitSaving(true);
    onMemLimitChange(service.definition.key, mb);
    try {
      await setMemoryLimit(service.definition.key, mb, level);
    } finally {
      setMemLimitSaving(false);
    }
  };

  // Empty core — show add service UI
  if (!service || !service.installed) {
    const trackingKey = installingService || selectedService;
    const activeInstall = trackingKey ? allInstalls[trackingKey] : undefined;
    const installing = activeInstall?.status === 'installing';
    const installSuccess = activeInstall?.status === 'success';
    const installError = activeInstall?.status === 'error';

    if (installing || installSuccess || installError) {
      const name = availableServices.find(s => s.key === trackingKey)?.name ?? trackingKey;
      return (
        <div className="rounded-lg border border-border/50 bg-card p-3.5 flex flex-col gap-2.5">
          <div className="flex items-center justify-between">
            <span className="font-mono text-[11px] text-muted-foreground uppercase tracking-wider">Core {coreIndex}</span>
          </div>
          <h3 className="font-medium text-sm">{name}</h3>
          {installing && (
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center gap-1.5 text-[hsl(var(--status-warning))]">
                <Loader2 className="h-3 w-3 animate-spin shrink-0" />
                <span className="font-mono text-[11px] truncate">{activeInstall?.progress || 'Installerar...'}</span>
              </div>
              <div className="flex items-center justify-between font-mono text-[10px] text-muted-foreground pl-4.5">
                <span>
                  {activeInstall?.step && activeInstall?.totalSteps
                    ? `Steg ${activeInstall.step}/${activeInstall.totalSteps}`
                    : ''}
                  {activeInstall?.percent != null ? ` · ${activeInstall.percent}%` : ''}
                </span>
                {activeInstall?.elapsed && <span>⏱ {activeInstall.elapsed}</span>}
              </div>
              <Progress
                value={activeInstall?.percent ?? undefined}
                className={`h-1 bg-secondary ${activeInstall?.percent == null ? 'animate-pulse' : ''}`}
              />
            </div>
          )}
          {installSuccess && (
            <span className="flex items-center gap-1 text-[11px] text-[hsl(var(--status-online))] font-mono">
              <CheckCircle2 className="h-3 w-3" /> Installerad
            </span>
          )}
          {installError && (
            <span className="flex items-center gap-1 text-[11px] text-destructive font-mono" title={activeInstall?.message}>
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
              <Button
                variant="default"
                size="sm"
                className="font-mono text-xs gap-1.5 w-full"
                disabled={installing}
                onClick={() => handleInstall(selectedService)}
              >
                <Download className="h-3 w-3" />
                Installera på Core {coreIndex}
              </Button>
            )}
            {selectedService && (
              <p className="font-mono text-[10px] text-muted-foreground">
                UI: :{uiPort} · Motor: :{enginePort}
              </p>
            )}
          </div>
        ) : null}
      </div>
    );
  }

  // Occupied core — show service info
  const { definition: def, online, version, cpu, ramMb, port, versionInfo, updateStatus, actionStatus, components, health, watchdog } = service;
  const isUpdating = updateStatus?.status === 'updating';
  const isPending = actionStatus?.status === 'pending';
  const hasUpdate = versionInfo?.hasUpdate ?? false;
  const installedVersion = versionInfo?.local || version || '—';
  const latestVersion = versionInfo?.remote || '—';
  const piIp = window.location.hostname;
  const isComponentBased = hasComponents(def);
  const permissions = service.permissions || def.permissions || [];

  const healthColor = health?.status === 'ok' ? 'bg-[hsl(var(--status-online))]'
    : health?.status === 'degraded' ? 'bg-[hsl(var(--status-warning))]'
    : health?.status === 'error' ? 'bg-destructive'
    : 'bg-muted-foreground/30';

  const healthLabel = health?.status === 'ok' ? 'Frisk'
    : health?.status === 'degraded' ? 'Degraderad'
    : health?.status === 'error' ? 'Fel'
    : health?.status === 'unreachable' ? 'Ej nåbar'
    : health?.status === 'offline' ? 'Offline'
    : '';

  const statusColor = online
    ? 'bg-[hsl(var(--status-online))]'
    : 'bg-[hsl(var(--status-offline))]';

  return (
    <div className={`rounded-lg border bg-card p-3.5 flex flex-col gap-2.5 transition-colors ${online ? 'border-border' : 'border-border/50'}`}>
      {/* Header */}
      <div className="flex items-center justify-between">
        <span className="font-mono text-[11px] text-muted-foreground uppercase tracking-wider">Core {coreIndex}</span>
        <div className="flex items-center gap-1.5">
          {!isComponentBased && <div className={`h-2 w-2 rounded-full ${statusColor}`} />}
          {port ? <span className="font-mono text-[11px] text-muted-foreground">:{port}</span> : null}
        </div>
      </div>

      <h3 className="font-medium text-sm leading-none">{def.name}</h3>

      {/* Component rows for engine/ui services */}
      {isComponentBased ? (
        <>
          <div className="flex flex-col border rounded bg-secondary/20 px-2 py-0.5 divide-y divide-border/30">
            {def.components?.engine && (
              <ComponentRow
                label="Motor"
                icon={Server}
                comp={components?.engine}
                alwaysOn={def.components.engine.alwaysOn}
                isPending={!!isPending}
                onAction={(action) => onServiceAction(def.key, action, 'engine')}
              />
            )}
            {def.components?.ui && (
              <ComponentRow
                label="UI"
                icon={Monitor}
                comp={components?.ui}
                alwaysOn={def.components.ui.alwaysOn}
                isPending={!!isPending}
                onAction={(action) => onServiceAction(def.key, action, 'ui')}
              />
            )}
          </div>
          {health && health.status !== 'unknown' && (
            <div className="flex items-center gap-2 px-2 py-0.5 font-mono text-[10px] text-muted-foreground">
              <div className={`h-1.5 w-1.5 rounded-full shrink-0 ${healthColor}`} />
              <span>{healthLabel}</span>
              {health.uptime != null && health.uptime > 0 && (
                <span className="text-muted-foreground/50">
                  {health.uptime >= 86400 ? `${Math.floor(health.uptime / 86400)}d` : health.uptime >= 3600 ? `${Math.floor(health.uptime / 3600)}h` : `${Math.floor(health.uptime / 60)}m`}
                </span>
              )}
              {health.memoryRss != null && health.memoryRss > 0 && (
                <span className="text-muted-foreground/50">{health.memoryRss}MB</span>
              )}
            </div>
          )}
        </>
      ) : (
        /* Legacy single-service resource row */
        <div className="flex flex-col gap-1">
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
          <WatchdogLine watchdog={watchdog} />
        </div>
      )}

      {/* RAM usage */}
      {memLimitMb !== null && (
        <div className="flex flex-col gap-1">
          <div className="flex items-center gap-1.5 font-mono text-[10px] text-muted-foreground">
            <MemoryStick className="h-3 w-3 shrink-0" />
            <span className="font-medium text-foreground">Max: {memoryMaxMb}MB</span>
            <span className={online && ramMb / memoryMaxMb > 0.8 ? 'text-[hsl(var(--status-warning))]' : ''}>
              Värde: {online ? ramMb : 0}MB
            </span>
            {memLimitSaving && <Loader2 className="h-2.5 w-2.5 animate-spin" />}
            {profile?.levels && (
              <Select value={memoryLevel} onValueChange={handleMemoryLevelChange}>
                <SelectTrigger className="ml-auto h-6 w-[86px] px-2 font-mono text-[10px]">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="low" className="font-mono text-xs">Låg</SelectItem>
                  <SelectItem value="balanced" className="font-mono text-xs">Balans</SelectItem>
                  <SelectItem value="high" className="font-mono text-xs">Hög</SelectItem>
                  <SelectItem value="custom" className="font-mono text-xs" disabled>Manuell</SelectItem>
                </SelectContent>
              </Select>
            )}
          </div>
          <div className="h-1.5 rounded-full bg-secondary/50 overflow-hidden">
            <div
              className="h-full rounded-full bg-primary"
              style={{ width: `${Math.min(100, ((online ? ramMb : 0) / memoryMaxMb) * 100)}%` }}
            />
          </div>
          <div className="flex justify-between font-mono text-[9px] text-muted-foreground/40">
            <span>0</span>
            <span>{memoryMaxMb}</span>
          </div>
        </div>
      )}

      {(permissions.length > 0 || service.configDir || service.dataDir || service.logDir) && (
        <div className="flex flex-col gap-1 rounded bg-secondary/20 px-2 py-1.5 font-mono text-[10px] text-muted-foreground">
          {permissions.length > 0 && (
            <div className="flex items-center gap-1.5 min-w-0">
              <KeyRound className="h-3 w-3 shrink-0" />
              <span className="truncate">Behörigheter: {permissions.join(', ')}</span>
            </div>
          )}
          {service.configDir && (
            <div className="flex items-center gap-1.5 min-w-0" title={service.configDir}>
              <FolderLock className="h-3 w-3 shrink-0" />
              <span className="truncate">Config: {service.configDir}</span>
            </div>
          )}
          {service.dataDir && (
            <div className="flex items-center gap-1.5 min-w-0" title={service.dataDir}>
              <Database className="h-3 w-3 shrink-0" />
              <span className="truncate">Data: {service.dataDir}</span>
            </div>
          )}
          {service.logDir && (
            <div className="flex items-center gap-1.5 min-w-0" title={service.logDir}>
              <Terminal className="h-3 w-3 shrink-0" />
              <span className="truncate">Logg: {service.logDir}</span>
            </div>
          )}
        </div>
      )}

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
        <span className="text-muted-foreground truncate" title={`Installerad: ${installedVersion} · GitHub: ${latestVersion}`}>
          Installerad {installedVersion} · GitHub {latestVersion}
        </span>
        <div className="flex items-center gap-1 shrink-0">
          {isUpdating ? (
            <span className="flex items-center gap-1 text-[hsl(var(--status-warning))]">
              <Loader2 className="h-3 w-3 animate-spin" /> Uppdaterar...
            </span>
          ) : hasUpdate ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => onUpdate(def.key)}
              className="h-5 w-5 p-0 text-[hsl(var(--status-warning))] hover:text-[hsl(var(--status-warning))] hover:bg-[hsl(var(--status-warning)/0.15)]"
              title="Uppdatera"
            >
              <RefreshCw className="h-3 w-3" />
            </Button>
          ) : (
            <Button
              variant="ghost"
              size="sm"
              disabled={checkingVersion}
              onClick={async () => {
                setCheckingVersion(true);
                try { await onCheckVersion(def.key); } catch {} finally { setCheckingVersion(false); }
              }}
              className="h-5 w-5 p-0 text-muted-foreground/50 hover:text-foreground hover:bg-secondary"
              title="Kolla version"
            >
              <RefreshCw className={`h-2.5 w-2.5 ${checkingVersion ? 'animate-spin' : ''}`} />
            </Button>
          )}
        </div>
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

      {/* Actions - full width buttons on separate rows */}
      <div className="flex flex-col gap-1.5 mt-auto">
        {!isComponentBased && (
          <>
            {!online ? (
              <Button variant="secondary" size="sm" className="font-mono text-[11px] gap-1 h-8 px-2 w-full" disabled={!!isPending} onClick={() => onServiceAction(def.key, 'start')}>
                <Play className="h-3 w-3" /> Starta
              </Button>
            ) : (
              <Button variant="secondary" size="sm" className="font-mono text-[11px] gap-1 h-8 px-2 w-full" disabled={!!isPending} onClick={() => onServiceAction(def.key, 'stop')}>
                <Square className="h-3 w-3" /> Stoppa
              </Button>
            )}
            <Button variant="secondary" size="sm" className="font-mono text-[11px] gap-1 h-8 px-2 w-full" disabled={!!isPending || !online} onClick={() => onServiceAction(def.key, 'restart')}>
              <RotateCcw className="h-3 w-3" /> Starta om
            </Button>
          </>
        )}
        {port ? (
          <a href={`http://${piIp}:${port}`} target="_blank" rel="noopener noreferrer" className="inline-flex items-center justify-center gap-1 h-8 px-2 rounded-md bg-secondary font-mono text-[11px] text-secondary-foreground hover:bg-secondary/80 transition-colors w-full">
            <ExternalLink className="h-3 w-3" /> Öppna
          </a>
        ) : (
          <div className="h-8 rounded-md bg-secondary/30 flex items-center justify-center font-mono text-[11px] text-muted-foreground/50 w-full">
            <ExternalLink className="h-3 w-3 mr-1" /> Öppna
          </div>
        )}
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="secondary" size="sm" className="font-mono text-[11px] gap-1 h-8 px-2 w-full text-destructive hover:text-destructive">
              <Trash2 className="h-3 w-3" /> Avinstallera
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

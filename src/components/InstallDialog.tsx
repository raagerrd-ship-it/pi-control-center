import { useState, useMemo } from 'react';
import { Download } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
  DialogDescription,
} from '@/components/ui/dialog';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import type { SystemStatus } from '@/lib/api';

interface InstallDialogProps {
  appKey: string;
  appName: string;
  usedPorts: number[];
  usedCores: number[];
  status: SystemStatus | null;
  onInstall: (app: string, port: number, core: number) => void;
  disabled?: boolean;
}

export function InstallDialog({
  appKey,
  appName,
  usedPorts,
  usedCores,
  status,
  onInstall,
  disabled,
}: InstallDialogProps) {
  const [open, setOpen] = useState(false);

  const suggestedPort = useMemo(() => {
    let p = 3000;
    while (usedPorts.includes(p)) p++;
    return p;
  }, [usedPorts]);

  const [port, setPort] = useState(suggestedPort);
  const [core, setCore] = useState('1');

  const portConflict = usedPorts.includes(port);
  const ramFree = status ? status.ramTotal - status.ramUsed : 999;
  const lowRam = ramFree < 100;

  const handleInstall = () => {
    onInstall(appKey, port, parseInt(core));
    setOpen(false);
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button
          variant="default"
          size="sm"
          className="font-mono text-xs gap-1.5 flex-1"
          disabled={disabled}
        >
          <Download className="h-3 w-3" />
          Installera
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle className="font-mono text-sm">Installera {appName}</DialogTitle>
          <DialogDescription className="text-xs text-muted-foreground">
            Välj port och CPU-core för tjänsten.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <div>
            <Label className="text-xs text-muted-foreground font-mono">Port</Label>
            <Input
              type="number"
              min={1024}
              max={65535}
              className="font-mono text-sm mt-1"
              value={port}
              onChange={e => setPort(parseInt(e.target.value) || 0)}
            />
            {portConflict && (
              <p className="text-[10px] text-destructive font-mono mt-1">
                Port {port} används redan
              </p>
            )}
          </div>

          <div>
            <Label className="text-xs text-muted-foreground font-mono">CPU Core</Label>
            <Select value={core} onValueChange={setCore}>
              <SelectTrigger className="font-mono text-sm mt-1">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="0" disabled>
                  Core 0 — Reserverad (Dashboard)
                </SelectItem>
                {[1, 2, 3].map(c => (
                  <SelectItem key={c} value={String(c)}>
                    Core {c}
                    {usedCores.includes(c) ? ' — Upptagen' : ''}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {lowRam && (
            <p className="text-[10px] text-[hsl(var(--status-warning))] font-mono">
              ⚠ Lite RAM kvar ({ramFree}MB). Installation kan misslyckas.
            </p>
          )}

          <Button
            onClick={handleInstall}
            disabled={portConflict || port < 1024}
            className="font-mono text-sm"
          >
            Installera
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

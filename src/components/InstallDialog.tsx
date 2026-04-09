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
import type { SystemStatus } from '@/lib/api';

interface InstallDialogProps {
  appKey: string;
  appName: string;
  core: number;
  usedPorts: number[];
  status: SystemStatus | null;
  onInstall: (app: string, port: number, core: number) => void;
  disabled?: boolean;
}

export function InstallDialog({
  appKey,
  appName,
  core,
  usedPorts,
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

  const portConflict = usedPorts.includes(port);
  const ramFree = status ? status.ramTotal - status.ramUsed : 999;
  const lowRam = ramFree < 100;

  const handleInstall = () => {
    onInstall(appKey, port, core);
    setOpen(false);
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button
          variant="default"
          size="sm"
          className="font-mono text-xs gap-1.5 w-full"
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
            Installeras på Core {core}. Välj port för tjänsten.
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
            Installera på Core {core}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

import { useState, useEffect, useCallback } from 'react';
import { Settings as SettingsIcon, AlertTriangle, Loader2, RotateCcw } from 'lucide-react';
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
import { triggerFactoryReset, triggerPiReset, fetchFactoryResetStatus } from '@/lib/api';

export interface DashboardSettings {
  deviceLabel: string;
}

const DEFAULT_SETTINGS: DashboardSettings = {
  deviceLabel: 'Pi Zero 2',
};

export function loadSettings(): DashboardSettings {
  try {
    const saved = localStorage.getItem('pi-control-center-settings');
    if (saved) {
      const parsed = JSON.parse(saved);
      return {
        deviceLabel: parsed.deviceLabel || DEFAULT_SETTINGS.deviceLabel,
      };
    }
  } catch {}
  return DEFAULT_SETTINGS;
}

export function Settings({ onSave }: { onSave: (s: DashboardSettings) => void }) {
  const [settings, setSettings] = useState(loadSettings);
  const [open, setOpen] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [resetDone, setResetDone] = useState(false);

  useEffect(() => {
    setSettings(loadSettings());
  }, [open]);

  const save = () => {
    localStorage.setItem('pi-control-center-settings', JSON.stringify(settings));
    onSave(settings);
    setOpen(false);
  };

  const handleFactoryReset = useCallback(async () => {
    setResetting(true);
    setResetDone(false);
    try {
      await triggerFactoryReset();
      // Poll for completion
      const poll = async () => {
        try {
          const result = await fetchFactoryResetStatus();
          if (result.status === 'success') {
            setResetting(false);
            setResetDone(true);
            localStorage.removeItem('pi-control-center-log');
            setTimeout(() => window.location.reload(), 1500);
          } else if (result.status === 'resetting') {
            setTimeout(poll, 2000);
          } else {
            setResetting(false);
          }
        } catch {
          setTimeout(poll, 3000);
        }
      };
      setTimeout(poll, 2000);
    } catch {
      setResetting(false);
    }
  }, []);

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="icon" className="text-muted-foreground hover:text-foreground">
          <SettingsIcon className="h-4 w-4" />
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle className="font-mono">Inställningar</DialogTitle>
          <DialogDescription className="text-xs text-muted-foreground">
            Konfigurera din Pi.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <div>
            <Label className="text-xs text-muted-foreground font-mono">Enhetsnamn</Label>
            <Input
              className="font-mono text-sm mt-1"
              placeholder="t.ex. Pi Zero 2"
              value={settings.deviceLabel}
              onChange={e => setSettings(s => ({ ...s, deviceLabel: e.target.value }))}
            />
          </div>

          <Button onClick={save} className="font-mono text-sm">Spara</Button>

          <div className="border-t border-border pt-4 mt-2">
            <Label className="text-xs text-muted-foreground font-mono mb-2 block">Farlig zon</Label>
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={resetting}
                  className="w-full font-mono text-xs text-destructive border-destructive/30 hover:bg-destructive/10 hover:text-destructive"
                >
                  {resetting ? (
                    <>
                      <Loader2 className="h-3 w-3 animate-spin mr-1.5" />
                      Återställer...
                    </>
                  ) : resetDone ? (
                    'Återställd ✓'
                  ) : (
                    <>
                      <AlertTriangle className="h-3 w-3 mr-1.5" />
                      Fabriksåterställning
                    </>
                  )}
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent className="max-w-sm">
                <AlertDialogHeader>
                  <AlertDialogTitle className="font-mono flex items-center gap-2">
                    <AlertTriangle className="h-4 w-4 text-destructive" />
                    Fabriksåterställning
                  </AlertDialogTitle>
                  <AlertDialogDescription className="text-xs leading-relaxed">
                    Detta avinstallerar <strong>alla tjänster</strong> och rensar alla tilldelningar.
                    Pi OS och Pi Control Center bevaras.
                    <br /><br />
                    <span className="text-destructive font-medium">Åtgärden kan inte ångras.</span>
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel className="font-mono text-xs">Avbryt</AlertDialogCancel>
                  <AlertDialogAction
                    onClick={handleFactoryReset}
                    className="font-mono text-xs bg-destructive text-destructive-foreground hover:bg-destructive/90"
                  >
                    Återställ till fabrik
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

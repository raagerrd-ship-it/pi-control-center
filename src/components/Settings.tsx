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
  const [resetPhase, setResetPhase] = useState('');
  const [piResetting, setPiResetting] = useState(false);
  const [piResetDone, setPiResetDone] = useState(false);
  const [piResetPhase, setPiResetPhase] = useState('');

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

  const handlePiReset = useCallback(async () => {
    setPiResetting(true);
    setPiResetDone(false);
    setPiResetPhase('Startar...');
    try {
      await triggerPiReset();
      let failures = 0;
      const MAX_FAILURES = 20;
      const poll = async () => {
        try {
          const result = await fetchFactoryResetStatus();
          failures = 0;
          if (result.status === 'success') {
            setPiResetting(false);
            setPiResetDone(true);
            localStorage.removeItem('pi-control-center-log');
            setTimeout(() => window.location.reload(), 2000);
          } else if (result.status === 'resetting') {
            const phase = (result as any).phase;
            if (phase) setPiResetPhase(phase);
            setTimeout(poll, 2000);
          } else {
            setPiResetting(false);
          }
        } catch {
          failures++;
          if (failures >= MAX_FAILURES) {
            setPiResetting(false);
            setPiResetPhase('');
            return;
          }
          setTimeout(poll, 3000);
        }
      };
      setTimeout(poll, 2000);
    } catch {
      setPiResetting(false);
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

          <div className="border-t border-border pt-4 mt-2 flex flex-col gap-2">
            <Label className="text-xs text-muted-foreground font-mono mb-1 block">Farlig zon</Label>

            {/* Återställ Pi — full reset + reinstall PCC */}
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={piResetting || resetting}
                  className="w-full font-mono text-xs text-destructive border-destructive/30 hover:bg-destructive/10 hover:text-destructive"
                >
                  {piResetting ? (
                    <>
                      <Loader2 className="h-3 w-3 animate-spin mr-1.5" />
                      <span className="truncate">{piResetPhase || 'Återställer...'}</span>
                    </>
                  ) : piResetDone ? (
                    'Återställd ✓'
                  ) : (
                    <>
                      <RotateCcw className="h-3 w-3 mr-1.5" />
                      Återställ Pi
                    </>
                  )}
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent className="max-w-sm">
                <AlertDialogHeader>
                  <AlertDialogTitle className="font-mono flex items-center gap-2">
                    <RotateCcw className="h-4 w-4 text-destructive" />
                    Återställ Pi
                  </AlertDialogTitle>
                  <AlertDialogDescription className="text-xs leading-relaxed">
                    Detta <strong>avinstallerar alla tjänster</strong> och installerar sedan om
                    senaste versionen av Pi Control Center.
                    <br /><br />
                    Efteråt kan du installera rena versioner av tjänsterna.
                    <br /><br />
                    <span className="text-destructive font-medium">Åtgärden kan inte ångras.</span>
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel className="font-mono text-xs">Avbryt</AlertDialogCancel>
                  <AlertDialogAction
                    onClick={handlePiReset}
                    className="font-mono text-xs bg-destructive text-destructive-foreground hover:bg-destructive/90"
                  >
                    Återställ Pi
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>

            {/* Fabriksåterställning — bara avinstallera tjänster */}
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={resetting || piResetting}
                  className="w-full font-mono text-[11px] text-muted-foreground hover:text-destructive"
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
                      Ta bort alla tjänster
                    </>
                  )}
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent className="max-w-sm">
                <AlertDialogHeader>
                    <AlertDialogTitle className="font-mono flex items-center gap-2">
                     <AlertTriangle className="h-4 w-4 text-destructive" />
                     Ta bort alla tjänster
                  </AlertDialogTitle>
                  <AlertDialogDescription className="text-xs leading-relaxed">
                    Detta avinstallerar <strong>alla tjänster</strong> och rensar alla tilldelningar.
                    Pi OS och Pi Control Center bevaras oförändrade.
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
                    Ta bort alla tjänster
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

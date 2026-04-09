import { useState, useEffect } from 'react';
import { Settings as SettingsIcon } from 'lucide-react';
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

export interface DashboardSettings {
  deviceLabel: string;
}

const DEFAULT_SETTINGS: DashboardSettings = {
  deviceLabel: 'Pi Zero 2',
};

export function loadSettings(): DashboardSettings {
  try {
    const saved = localStorage.getItem('pi-dashboard-settings');
    if (saved) {
      const parsed = JSON.parse(saved);
      return { deviceLabel: parsed.deviceLabel || DEFAULT_SETTINGS.deviceLabel };
    }
  } catch {}
  return DEFAULT_SETTINGS;
}

export function Settings({ onSave }: { onSave: (s: DashboardSettings) => void }) {
  const [settings, setSettings] = useState(loadSettings);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    setSettings(loadSettings());
  }, [open]);

  const save = () => {
    localStorage.setItem('pi-dashboard-settings', JSON.stringify(settings));
    onSave(settings);
    setOpen(false);
  };

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
        </div>
      </DialogContent>
    </Dialog>
  );
}

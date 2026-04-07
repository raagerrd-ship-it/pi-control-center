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
  piIp: string;
  apiPort: number;
  services: { key: string; name: string; port: number }[];
}

const DEFAULT_SETTINGS: DashboardSettings = {
  piIp: window.location.hostname,
  apiPort: 8585,
  services: [
    { key: 'lotus-lantern', name: 'Lotus Lantern Control', port: 3001 },
    { key: 'cast-away', name: 'Cast Away Web', port: 3000 },
    { key: 'sonos-gateway', name: 'Sonos Gateway', port: 3002 },
  ],
};

export function loadSettings(): DashboardSettings {
  try {
    const saved = localStorage.getItem('pi-dashboard-settings');
    if (saved) return { ...DEFAULT_SETTINGS, ...JSON.parse(saved) };
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
            Konfigurera anslutning till din Pi.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-xs text-muted-foreground">Pi IP</Label>
              <Input
                className="font-mono text-sm mt-1"
                value={settings.piIp}
                onChange={e => setSettings(s => ({ ...s, piIp: e.target.value }))}
              />
            </div>
            <div>
              <Label className="text-xs text-muted-foreground">API Port</Label>
              <Input
                className="font-mono text-sm mt-1"
                type="number"
                value={settings.apiPort}
                onChange={e => setSettings(s => ({ ...s, apiPort: Number(e.target.value) }))}
              />
            </div>
          </div>
          {settings.services.map((svc, i) => (
            <div key={svc.key} className="flex items-center gap-2">
              <span className="text-xs text-muted-foreground flex-1 truncate">{svc.name}</span>
              <Input
                className="font-mono text-sm w-20"
                type="number"
                value={svc.port}
                onChange={e => {
                  const updated = [...settings.services];
                  updated[i] = { ...svc, port: Number(e.target.value) };
                  setSettings(s => ({ ...s, services: updated }));
                }}
              />
            </div>
          ))}
          <Button onClick={save} className="font-mono text-sm">Spara</Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

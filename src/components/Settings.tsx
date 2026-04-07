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

export interface ServiceConfig {
  key: string;
  name: string;
  port: number;
  host: string;       // IP/hostname for this specific service
  apiPort: number;     // API port on that host
  deviceLabel: string; // e.g. "Pi Zero 2 #1", "Pi 4"
}

export interface DashboardSettings {
  piIp: string;       // Default/dashboard Pi IP
  apiPort: number;     // Default API port
  services: ServiceConfig[];
}

const DEFAULT_HOST = window.location.hostname;

const DEFAULT_SETTINGS: DashboardSettings = {
  piIp: DEFAULT_HOST,
  apiPort: 8585,
  services: [
    { key: 'lotus-lantern', name: 'Lotus Lantern Control', port: 3001, host: DEFAULT_HOST, apiPort: 8585, deviceLabel: 'Pi Zero 2' },
    { key: 'cast-away', name: 'Cast Away Web', port: 3000, host: DEFAULT_HOST, apiPort: 8585, deviceLabel: 'Pi Zero 2' },
    { key: 'sonos-gateway', name: 'Sonos Gateway', port: 3002, host: DEFAULT_HOST, apiPort: 8585, deviceLabel: 'Pi Zero 2' },
  ],
};

export function loadSettings(): DashboardSettings {
  try {
    const saved = localStorage.getItem('pi-dashboard-settings');
    if (saved) {
      const parsed = JSON.parse(saved);
      // Migrate old format: add host/apiPort/deviceLabel if missing
      if (parsed.services) {
        parsed.services = parsed.services.map((svc: any) => ({
          host: parsed.piIp || DEFAULT_HOST,
          apiPort: parsed.apiPort || 8585,
          deviceLabel: 'Pi Zero 2',
          ...svc,
        }));
      }
      return { ...DEFAULT_SETTINGS, ...parsed };
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

  const updateService = (i: number, patch: Partial<ServiceConfig>) => {
    const updated = [...settings.services];
    updated[i] = { ...updated[i], ...patch };
    setSettings(s => ({ ...s, services: updated }));
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="icon" className="text-muted-foreground hover:text-foreground">
          <SettingsIcon className="h-4 w-4" />
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-md max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="font-mono">Inställningar</DialogTitle>
          <DialogDescription className="text-xs text-muted-foreground">
            Konfigurera anslutning till dina Pi-enheter.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-5">
          {/* Dashboard default */}
          <div>
            <Label className="text-xs text-muted-foreground font-mono uppercase tracking-wider">Dashboard-Pi</Label>
            <div className="grid grid-cols-2 gap-2 mt-1.5">
              <Input
                className="font-mono text-sm"
                placeholder="IP"
                value={settings.piIp}
                onChange={e => setSettings(s => ({ ...s, piIp: e.target.value }))}
              />
              <Input
                className="font-mono text-sm"
                type="number"
                placeholder="API port"
                value={settings.apiPort}
                onChange={e => setSettings(s => ({ ...s, apiPort: Number(e.target.value) }))}
              />
            </div>
          </div>

          {/* Per-service config */}
          {settings.services.map((svc, i) => (
            <div key={svc.key} className="border rounded-lg p-3 bg-secondary/30">
              <span className="text-xs font-medium">{svc.name}</span>
              <div className="grid grid-cols-3 gap-2 mt-2">
                <div>
                  <Label className="text-[10px] text-muted-foreground">Host / IP</Label>
                  <Input
                    className="font-mono text-xs mt-0.5"
                    value={svc.host}
                    onChange={e => updateService(i, { host: e.target.value })}
                  />
                </div>
                <div>
                  <Label className="text-[10px] text-muted-foreground">Port</Label>
                  <Input
                    className="font-mono text-xs mt-0.5"
                    type="number"
                    value={svc.port}
                    onChange={e => updateService(i, { port: Number(e.target.value) })}
                  />
                </div>
                <div>
                  <Label className="text-[10px] text-muted-foreground">API port</Label>
                  <Input
                    className="font-mono text-xs mt-0.5"
                    type="number"
                    value={svc.apiPort}
                    onChange={e => updateService(i, { apiPort: Number(e.target.value) })}
                  />
                </div>
              </div>
              <div className="mt-2">
                <Label className="text-[10px] text-muted-foreground">Enhet</Label>
                <Input
                  className="font-mono text-xs mt-0.5"
                  placeholder="t.ex. Pi Zero 2 #1"
                  value={svc.deviceLabel}
                  onChange={e => updateService(i, { deviceLabel: e.target.value })}
                />
              </div>
            </div>
          ))}
          <Button onClick={save} className="font-mono text-sm">Spara</Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

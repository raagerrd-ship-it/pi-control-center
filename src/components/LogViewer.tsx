import { useState, useRef, useEffect, createContext, useContext, type ReactNode } from 'react';
import { FileText, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { fetchLogs } from '@/lib/api';

// Shared state context so the icon button and panel can communicate
interface LogState {
  open: boolean;
  toggle: () => void;
}

const LogContext = createContext<LogState | null>(null);

export function LogProvider({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <LogContext.Provider value={{ open, toggle: () => setOpen(o => !o) }}>
      {children}
    </LogContext.Provider>
  );
}

interface LogViewerProps {
  appKey: string;
  appName: string;
  asButton?: boolean;
  asIconButton?: boolean;
  showLabel?: boolean;
  panelOnly?: boolean;
}

export function LogViewer({ appKey, appName, asButton, asIconButton, showLabel, panelOnly }: LogViewerProps) {
  const ctx = useContext(LogContext);
  const [localOpen, setLocalOpen] = useState(false);
  const [logType, setLogType] = useState<'update' | 'install' | 'service'>('service');
  const [log, setLog] = useState<string>('');
  const [loading, setLoading] = useState(false);
  const scrollRef = useRef<HTMLPreElement>(null);

  const isOpen = ctx ? ctx.open : localOpen;
  const toggleOpen = ctx ? ctx.toggle : () => setLocalOpen(o => !o);

  const loadLog = async (type: 'update' | 'install' | 'service') => {
    setLogType(type);
    setLoading(true);
    try {
      const mappedType = type === 'service' ? 'update' : type;
      const text = await fetchLogs(appKey, mappedType);
      setLog(text);
    } catch {
      setLog('Kunde inte hämta loggar');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (isOpen) {
      loadLog(logType);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, appKey]);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [log]);

  // Icon button mode — just renders the trigger
  if (asIconButton) {
    return (
      <Button
        variant="secondary"
        size="sm"
        className={`font-mono text-[11px] h-7 ${showLabel ? 'gap-1 px-2' : 'w-7 p-0'} ${isOpen ? 'bg-accent text-foreground' : ''}`}
        onClick={toggleOpen}
        title="Loggar"
      >
        <FileText className="h-3 w-3" />
        {showLabel && 'Logg'}
      </Button>
    );
  }

  // Panel mode — just renders the expandable log panel
  if (panelOnly) {
    if (!isOpen) return null;
    return (
      <div className="rounded border bg-background p-2 mt-1">
        <div className="flex items-center justify-between mb-2">
          <div className="flex gap-1">
            <Button
              variant={logType === 'update' ? 'secondary' : 'ghost'}
              size="sm"
              className="font-mono text-[10px] h-6 px-2"
              onClick={() => loadLog('update')}
            >
              Uppdatering
            </Button>
            <Button
              variant={logType === 'install' ? 'secondary' : 'ghost'}
              size="sm"
              className="font-mono text-[10px] h-6 px-2"
              onClick={() => loadLog('install')}
            >
              Installation
            </Button>
          </div>
          <Button
            variant="ghost"
            size="sm"
            className="h-6 w-6 p-0 text-muted-foreground hover:text-foreground"
            onClick={toggleOpen}
          >
            <X className="h-3 w-3" />
          </Button>
        </div>
        <pre
          ref={scrollRef}
          className="font-mono text-[10px] leading-relaxed text-muted-foreground bg-secondary/50 rounded p-2 max-h-32 overflow-auto whitespace-pre-wrap break-all"
        >
          {loading ? 'Laddar...' : log}
        </pre>
      </div>
    );
  }

  // Default standalone mode (button + panel together)
  if (!isOpen) {
    return (
      <Button
        variant="secondary"
        size="sm"
        className={`font-mono text-xs gap-1 ${asButton ? 'flex-1' : ''}`}
        onClick={toggleOpen}
      >
        <FileText className="h-3 w-3" />
        Loggar
      </Button>
    );
  }

  return (
    <div className="rounded border bg-background p-2 mt-1 col-span-full">
      <div className="flex items-center justify-between mb-2">
        <div className="flex gap-1">
          <Button
            variant={logType === 'update' ? 'secondary' : 'ghost'}
            size="sm"
            className="font-mono text-[10px] h-6 px-2"
            onClick={() => loadLog('update')}
          >
            Uppdatering
          </Button>
          <Button
            variant={logType === 'install' ? 'secondary' : 'ghost'}
            size="sm"
            className="font-mono text-[10px] h-6 px-2"
            onClick={() => loadLog('install')}
          >
            Installation
          </Button>
        </div>
        <Button
          variant="ghost"
          size="sm"
          className="h-6 w-6 p-0 text-muted-foreground hover:text-foreground"
          onClick={toggleOpen}
        >
          <X className="h-3 w-3" />
        </Button>
      </div>
      <pre
        ref={scrollRef}
        className="font-mono text-[10px] leading-relaxed text-muted-foreground bg-secondary/50 rounded p-2 max-h-32 overflow-auto whitespace-pre-wrap break-all"
      >
        {loading ? 'Laddar...' : log}
      </pre>
    </div>
  );
}

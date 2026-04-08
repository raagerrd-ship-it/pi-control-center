import { type ConnectionLog as LogEntry } from '@/hooks/useSystemStatus';
import { Terminal } from 'lucide-react';

interface Props {
  logs: LogEntry[];
}

export function ConnectionLog({ logs }: Props) {
  if (logs.length === 0) return null;

  return (
    <section className="mt-6">
      <h2 className="font-mono text-xs uppercase tracking-wider text-muted-foreground mb-3 flex items-center gap-1.5">
        <Terminal className="h-3 w-3" />
        Logg
      </h2>
      <div className="rounded-lg border bg-card p-3 max-h-40 overflow-y-auto">
        <div className="space-y-0.5 font-mono text-[11px]">
          {logs.map((log, i) => (
            <div key={i} className="flex gap-2">
              <span className="text-muted-foreground/50 shrink-0">{log.time}</span>
              <span className={
                log.type === 'error' ? 'text-destructive' :
                log.type === 'success' ? 'text-[hsl(var(--status-online))]' :
                'text-muted-foreground'
              }>
                {log.message}
              </span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

import { useEffect, useRef } from 'react';
import { Terminal, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { useActivityLog } from '@/hooks/useActivityLog';

export function ActivityLog() {
  const { entries, clearLog } = useActivityLog();
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [entries]);

  if (entries.length === 0) return null;

  return (
    <section className="mt-6">
      <div className="flex items-center justify-between mb-3">
        <h2 className="font-mono text-xs uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
          <Terminal className="h-3 w-3" />
          Logg
        </h2>
        <Button variant="ghost" size="sm" className="h-6 px-1.5 text-muted-foreground/50 hover:text-destructive" onClick={clearLog} title="Rensa logg">
          <Trash2 className="h-3 w-3" />
        </Button>
      </div>
      <div
        ref={scrollRef}
        className="rounded-lg border bg-card p-3 max-h-48 overflow-y-auto"
      >
        <div className="space-y-0.5 font-mono text-[11px]">
          {entries.map((entry, i) => (
            <div key={i} className="flex gap-2">
              <span className="text-muted-foreground/50 shrink-0">{entry.time}</span>
              <span className="text-muted-foreground/70 shrink-0">[{entry.source}]</span>
              <span
                className={
                  entry.type === 'error'
                    ? 'text-destructive'
                    : entry.type === 'success'
                      ? 'text-[hsl(var(--status-online))]'
                      : 'text-muted-foreground'
                }
              >
                {entry.message}
              </span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

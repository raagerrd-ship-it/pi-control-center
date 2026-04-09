import { BrowserRouter, Route, Routes } from "react-router-dom";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { Toaster } from "@/components/ui/toaster";
import { TooltipProvider } from "@/components/ui/tooltip";
import { ActivityLogProvider } from "@/hooks/useActivityLog";
import Index from "./pages/Index.tsx";
import NotFound from "./pages/NotFound.tsx";
import LotusControl from "./pages/LotusControl.tsx";

const App = () => (
  <ActivityLogProvider>
    <TooltipProvider>
      <Toaster />
      <Sonner />
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<Index />} />
          <Route path="/lotus" element={<LotusControl />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
      </BrowserRouter>
    </TooltipProvider>
  </ActivityLogProvider>
);

export default App;

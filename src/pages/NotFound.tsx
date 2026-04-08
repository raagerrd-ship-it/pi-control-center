import { useLocation } from "react-router-dom";
import { useEffect } from "react";

const NotFound = () => {
  const location = useLocation();

  useEffect(() => {
    console.error("404: Sidan finns inte:", location.pathname);
  }, [location.pathname]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background">
      <div className="text-center">
        <h1 className="mb-4 text-4xl font-bold font-mono">404</h1>
        <p className="mb-4 text-xl text-muted-foreground">Sidan hittades inte</p>
        <a href="/" className="text-primary underline hover:text-primary/90 font-mono text-sm">
          Tillbaka till Dashboard
        </a>
      </div>
    </div>
  );
};

export default NotFound;
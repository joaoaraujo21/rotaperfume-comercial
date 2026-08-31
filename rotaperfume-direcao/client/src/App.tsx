import { createBrowserRouter, RouterProvider, NavLink, Outlet } from 'react-router';
import { useState, useEffect } from 'react';
import {
  Button,
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  useIsMobile,
} from '@databricks/appkit-ui/react';
import { Menu } from 'lucide-react';
import { SemanaPage } from './pages/semana/SemanaPage';
import { AcompanhamentoPage } from './pages/acompanhamento/AcompanhamentoPage';
import { GeniePage } from './pages/genie/GeniePage';

const navLinkClass = ({ isActive }: { isActive: boolean }) =>
  `px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
    isActive
      ? 'bg-primary text-primary-foreground'
      : 'text-muted-foreground hover:bg-muted hover:text-foreground'
  }`;

const mobileNavLinkClass = ({ isActive }: { isActive: boolean }) =>
  `block px-3 py-2 rounded-md text-sm font-medium transition-colors ${
    isActive
      ? 'bg-primary text-primary-foreground'
      : 'text-muted-foreground hover:bg-muted hover:text-foreground'
  }`;

type NavLinkClassFn = (props: { isActive: boolean }) => string;

function NavLinks({ className, linkClass, onClick }: { className?: string; linkClass: NavLinkClassFn; onClick?: () => void }) {
  return (
    <nav className={className}>
      <NavLink to="/" end className={linkClass} onClick={onClick}>
        📊 A semana
      </NavLink>
      <NavLink to="/perguntar" className={linkClass} onClick={onClick}>
        💬 Perguntar
      </NavLink>
      <NavLink to="/acompanhamento" className={linkClass} onClick={onClick}>
        📋 Acompanhamento
      </NavLink>
    </nav>
  );
}

function Layout() {
  const isMobile = useIsMobile();
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  // Vendedor filter — lives HERE so it survives table remounts.
  // Passing as Outlet context avoids prop-drilling through createBrowserRouter.
  const [vendedor, setVendedor] = useState<string>('Todos');

  useEffect(() => {
    if (!isMobile) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setMobileNavOpen(false);
    }
  }, [isMobile]);

  return (
    <div className="min-h-screen bg-background flex flex-col">
      <header className="border-b px-4 md:px-6 py-3 flex items-center gap-4">
        <span className="text-2xl" role="img" aria-hidden="true">🌸</span>
        <div>
          <h1 className="text-lg font-semibold text-foreground">Rota do Perfume</h1>
          <p className="text-xs text-muted-foreground">Direção Comercial</p>
        </div>
        <NavLinks className="hidden md:flex gap-1 ml-4" linkClass={navLinkClass} />
        <div className="ml-auto md:hidden">
          <Sheet open={mobileNavOpen} onOpenChange={setMobileNavOpen}>
            <Button variant="ghost" size="icon" onClick={() => setMobileNavOpen(true)}>
              <Menu className="h-5 w-5" />
              <span className="sr-only">Open navigation</span>
            </Button>
            <SheetContent side="left">
              <SheetHeader>
                <SheetTitle>Navegação</SheetTitle>
              </SheetHeader>
              <NavLinks className="flex flex-col gap-1" linkClass={mobileNavLinkClass} onClick={() => setMobileNavOpen(false)} />
            </SheetContent>
          </Sheet>
        </div>
      </header>

      <main className="flex-1 p-4 md:p-6">
        <Outlet context={{ vendedor, setVendedor }} />
      </main>
    </div>
  );
}

const router = createBrowserRouter([
  {
    element: <Layout />,
    children: [
      { path: '/', element: <SemanaPage /> },
      { path: '/perguntar', element: <GeniePage /> },
      { path: '/acompanhamento', element: <AcompanhamentoPage /> },
    ],
  },
]);

export default function App() {
  return <RouterProvider router={router} />;
}
